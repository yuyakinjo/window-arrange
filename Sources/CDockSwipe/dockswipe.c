/*
 * Synthetic Dock swipe posting: switches one space with no visible animation.
 *
 * Taken from Interspace (https://github.com/cnrad/interspace, MIT, Copyright (c) 2026 cnrad),
 * keeping the posting part and the keyboard tap (the trackpad gesture tap was left out).
 * The event format and the macOS 27 IOHID payload are adapted from
 * InstantSpaceSwitcher (https://github.com/jurplel/InstantSpaceSwitcher).
 *
 * MIT License
 *
 * Copyright (c) 2026 jurplel
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include "include/dockswipe.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

// MARK: - Private event constants

static const CGEventField kCGSEventTypeField = (CGEventField)55;
static const CGEventField kCGEventGestureHIDType = (CGEventField)110;
static const CGEventField kCGEventGestureSwipeMask = (CGEventField)115;
static const CGEventField kCGEventGestureSwipeMotion = (CGEventField)123;
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;
static const CGEventField kCGEventGestureSwipePositionX = (CGEventField)125;
static const CGEventField kCGEventGestureSwipePositionY = (CGEventField)126;
static const CGEventField kCGEventGestureSwipeVelocityX = (CGEventField)129;
static const CGEventField kCGEventGestureSwipeVelocityY = (CGEventField)130;
static const CGEventField kCGEventGesturePhase = (CGEventField)132;
static const CGEventField kCGEventGesturePhaseAlias = (CGEventField)134;
static const CGEventField kCGEventGestureZoomDeltaY = (CGEventField)138;
static const CGEventField kCGEventSourceUnixProcessIDAlias = (CGEventField)169;

static const uint32_t kIOHIDEventTypeDockSwipe = 23;
static const uint32_t kIOHIDEventTypeVelocity = 9;
static const uint32_t kIOHIDEventTypeFluidTouchGesture = 23;
static const uint16_t kIOHIDGestureFlavorDockPrimary = 3;

enum {
    kCGSEventGesture = 29,
    kCGSEventDockControl = 30,
};

enum {
    kCGSGesturePhaseBegan = 1,
    kCGSGesturePhaseChanged = 2,
    kCGSGesturePhaseEnded = 4,
    kCGSGesturePhaseCancelled = 8,
};

static const uint16_t kCGGestureMotionHorizontal = 1;

// Smallest non-zero 16.16 progress: keeps the direction, leaves the Dock nothing to animate.
static const double kMinimalProgress = 0.000016;
// The fling on the ended phase is what commits the switch on macOS 27 (16.16 fixed point, max ~32767).
static const double kModernFlingVelocity = 9999.0;
static const double kLegacyVelocity = 2000.0;

// MARK: - macOS 27 payload

#pragma pack(push, 1)

typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} IOHIDEventBase;

typedef struct {
    IOHIDEventBase base;
    int32_t position_x;
    int32_t position_y;
    int32_t position_z;
    uint32_t swipe_mask;
    uint16_t gesture_motion;
    uint16_t gesture_flavor;
    int32_t swipe_progress;
} IOHIDFluidTouchGestureData;

typedef struct {
    IOHIDEventBase base;
    int32_t velocity_x;
    int32_t velocity_y;
    int32_t velocity_z;
} IOHIDVelocityEventData;

typedef struct {
    uint64_t timestamp;
    uint64_t sender_id;
    uint32_t options;
    uint32_t attribute_length;
    uint32_t event_count;
} IOHIDSystemQueueElementHeader;

#pragma pack(pop)

_Static_assert(sizeof(IOHIDEventBase) == 16, "unexpected IOHID event base layout");
_Static_assert(sizeof(IOHIDFluidTouchGestureData) == 40, "unexpected IOHID fluid gesture layout");
_Static_assert(sizeof(IOHIDVelocityEventData) == 28, "unexpected IOHID velocity layout");
_Static_assert(sizeof(IOHIDSystemQueueElementHeader) == 28, "unexpected IOHID queue header layout");

static int32_t to_fixed1616(double value) {
    int32_t fixed = (int32_t)(value * 65536.0);
    if (fixed == 0 && value != 0.0) {
        return value > 0.0 ? 1 : -1;
    }
    return fixed;
}

static uint8_t *make_iohid_payload(CGEventRef event, size_t *outLength) {
    int64_t phase = CGEventGetIntegerValueField(event, kCGEventGesturePhase);
    int64_t motion = CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion);
    double progress = CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress);
    double posX = CGEventGetDoubleValueField(event, kCGEventGestureSwipePositionX);
    double posY = CGEventGetDoubleValueField(event, kCGEventGestureSwipePositionY);
    double velX = CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityX);
    double velY = CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityY);
    int64_t swipeMask = CGEventGetIntegerValueField(event, kCGEventGestureSwipeMask);

    bool includeVelocity = (velX != 0.0 || velY != 0.0 || phase == kCGSGesturePhaseEnded);
    size_t length = sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData);
    if (includeVelocity) {
        length += sizeof(IOHIDVelocityEventData);
    }

    uint8_t *payload = (uint8_t *)calloc(1, length);
    if (!payload) {
        return NULL;
    }

    IOHIDSystemQueueElementHeader *header = (IOHIDSystemQueueElementHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp != 0 ? timestamp : mach_absolute_time();
    header->event_count = includeVelocity ? 2 : 1;

    IOHIDFluidTouchGestureData *fluid =
        (IOHIDFluidTouchGestureData *)(payload + sizeof(IOHIDSystemQueueElementHeader));
    fluid->base.size = sizeof(IOHIDFluidTouchGestureData);
    fluid->base.type = kIOHIDEventTypeFluidTouchGesture;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->position_x = to_fixed1616(posX);
    fluid->position_y = to_fixed1616(posY);
    fluid->swipe_mask = (uint32_t)swipeMask;
    fluid->gesture_motion = (uint16_t)motion;
    fluid->gesture_flavor = kIOHIDGestureFlavorDockPrimary;
    fluid->swipe_progress = to_fixed1616(progress);

    if (includeVelocity) {
        IOHIDVelocityEventData *velocity = (IOHIDVelocityEventData *)(
            payload + sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData));
        velocity->base.size = sizeof(IOHIDVelocityEventData);
        velocity->base.type = kIOHIDEventTypeVelocity;
        velocity->base.depth = 1;
        velocity->velocity_x = to_fixed1616(velX);
        velocity->velocity_y = to_fixed1616(velY);
    }

    *outLength = length;
    return payload;
}

/// Appends the IOHID payload (field 4205) to the serialized event. Returns a retained event.
static CGEventRef augment_event(CGEventRef event) {
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) {
        return NULL;
    }

    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);

    // Serialized format version 2 only.
    if (length < 4 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != 2) {
        CFRelease(data);
        return NULL;
    }

    size_t payloadLength = 0;
    uint8_t *payload = make_iohid_payload(event, &payloadLength);
    if (!payload) {
        CFRelease(data);
        return NULL;
    }

    size_t newLength = (size_t)length + 4 + payloadLength;
    uint8_t *newBytes = (uint8_t *)malloc(newLength);
    if (!newBytes) {
        free(payload);
        CFRelease(data);
        return NULL;
    }

    memcpy(newBytes, bytes, (size_t)length);
    // 4-byte tag: payload size, then field ID 4205, both big-endian.
    newBytes[length] = (uint8_t)((payloadLength >> 8) & 0xFF);
    newBytes[length + 1] = (uint8_t)(payloadLength & 0xFF);
    newBytes[length + 2] = (uint8_t)((4205 >> 8) & 0xFF);
    newBytes[length + 3] = (uint8_t)(4205 & 0xFF);
    memcpy(newBytes + length + 4, payload, payloadLength);

    free(payload);
    CFRelease(data);

    CFDataRef newData = CFDataCreate(kCFAllocatorDefault, newBytes, (CFIndex)newLength);
    free(newBytes);
    if (!newData) {
        return NULL;
    }

    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, newData);
    CFRelease(newData);
    return result;
}

bool ds_requires_event_augmentation(void) {
    static int cached = -1;
    if (cached != -1) {
        return cached;
    }

    char version[32] = {0};
    size_t size = sizeof(version);
    int major = 0;
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) != 0 ||
        sscanf(version, "%d", &major) < 1) {
        cached = 0;
        return false;
    }

    cached = (major >= 27) ? 1 : 0;
    return cached;
}

// MARK: - Posting

// On macOS 27 "right" is negative, and the Dock reads the posted sign through the
// natural scrolling preference, so it flips again with natural scrolling off.
// Read on every switch (instead of caching with a notification observer) so a changed setting applies at once.
static double modern_swipe_sign(DSDirection direction) {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    Boolean valid = false;
    Boolean natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"),
                                                      kCFPreferencesAnyApplication, &valid);
    const double sign = (direction == DSDirectionRight) ? -1.0 : 1.0;
    return (!valid || natural) ? sign : -sign;
}

static bool post_modern(int phase, DSDirection direction) {
    const double sign = modern_swipe_sign(direction);

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) {
        return false;
    }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, sign * kMinimalProgress);
    // Fields a real trackpad swipe carries.
    CGEventSetIntegerValueField(ev, kCGEventGesturePhaseAlias, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureZoomDeltaY, 3.0);
    CGEventSetDoubleValueField(ev, kCGEventSourceUnixProcessIDAlias, (double)mach_absolute_time());
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipePositionX, 0.1);
    if (phase == kCGSGesturePhaseEnded) {
        CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, sign * kModernFlingVelocity);
    }

    CGEventRef augmented = augment_event(ev);
    CFRelease(ev);
    if (!augmented) {
        return false;
    }

    // The Dock ignores a DockControl event without a companion gesture event.
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) {
        CFRelease(augmented);
        return false;
    }
    CGEventSetIntegerValueField(companion, kCGSEventTypeField, kCGSEventGesture);

    CGEventPost(kCGSessionEventTap, augmented);
    CGEventPost(kCGSessionEventTap, companion);
    CFRelease(augmented);
    CFRelease(companion);
    return true;
}

static bool post_legacy(int phase, DSDirection direction) {
    const bool isRight = (direction == DSDirectionRight);
    const double velocity = isRight ? kLegacyVelocity : -kLegacyVelocity;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) {
        return false;
    }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, isRight ? kMinimalProgress : -kMinimalProgress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, velocity);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, velocity);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
    return true;
}

static bool post_phase(int phase, DSDirection direction) {
    return ds_requires_event_augmentation() ? post_modern(phase, direction)
                                            : post_legacy(phase, direction);
}

bool ds_post_switch(DSDirection direction) {
    // All three phases are needed; with only began + ended Mission Control breaks.
    return post_phase(kCGSGesturePhaseBegan, direction)
        && post_phase(kCGSGesturePhaseChanged, direction)
        && post_phase(kCGSGesturePhaseEnded, direction);
}


// MARK: - Keyboard shortcuts

// The tap is on a thread of its own. Every key press of the user waits for this callback, so it must
// never wait for the main thread. The state it reads is atomic and the callback only compares numbers.

static const CGEventFlags kShortcutModifiers =
    kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;

static CFMachPortRef gKeyTap = NULL;
static DSKeyHandler gKeyHandler = NULL;
static atomic_bool gKeysEnabled = false;
// Index 0 is left, 1 is right, as in DSDirection.
static atomic_int gKeyCode[2] = {-1, -1};
static atomic_ullong gKeyFlags[2] = {0, 0};
// The key down was swallowed, so its key up must be too.
static atomic_bool gKeyHeld[2] = {false, false};

static CGEventRef key_tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gKeyTap) CGEventTapEnable(gKeyTap, true);
        return event;
    }
    if (type != kCGEventKeyDown && type != kCGEventKeyUp) {
        return event;
    }

    int code = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    if (type == kCGEventKeyUp) {
        for (int direction = 0; direction < 2; direction++) {
            if (code == atomic_load(&gKeyCode[direction]) && atomic_exchange(&gKeyHeld[direction], false)) {
                return NULL;
            }
        }
        return event;
    }

    if (!atomic_load(&gKeysEnabled)) {
        return event;
    }
    unsigned long long flags = (unsigned long long)(CGEventGetFlags(event) & kShortcutModifiers);
    for (int direction = 0; direction < 2; direction++) {
        int wanted = atomic_load(&gKeyCode[direction]);
        if (wanted < 0 || code != wanted || flags != atomic_load(&gKeyFlags[direction])) {
            continue;
        }
        atomic_store(&gKeyHeld[direction], true);
        // A key that is held down sends the press again and again. Only the first one is a step.
        bool isRepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
        if (!isRepeat && gKeyHandler) {
            gKeyHandler(direction == 0 ? DSDirectionLeft : DSDirectionRight);
        }
        return NULL;
    }
    return event;
}

static void *key_tap_thread(void *context) {
    CFRunLoopSourceRef source = (CFRunLoopSourceRef)context;
    pthread_setname_np("WindowArrange.spaceKeys");
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CGEventTapEnable(gKeyTap, true);
    CFRunLoopRun();
    return NULL;
}

bool ds_keys_install(DSKeyHandler handler) {
    if (gKeyTap) {
        return true;
    }
    gKeyHandler = handler;

    // Where key events enter the window server: before macOS reads them as its own shortcuts.
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                         mask, key_tap_callback, NULL);
    if (!tap) {
        return false;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    if (!source) {
        CFRelease(tap);
        return false;
    }
    gKeyTap = tap;

    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    // Key presses of the user wait for this thread.
    pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0);
    int failed = pthread_create(&thread, &attributes, key_tap_thread, (void *)source);
    pthread_attr_destroy(&attributes);
    if (failed) {
        CFRelease(source);
        CFRelease(tap);
        gKeyTap = NULL;
        return false;
    }
    return true;
}

void ds_keys_configure(bool enabled, int leftKeyCode, unsigned long long leftFlags,
                       int rightKeyCode, unsigned long long rightFlags) {
    atomic_store(&gKeyCode[0], leftKeyCode);
    atomic_store(&gKeyFlags[0], leftFlags & kShortcutModifiers);
    atomic_store(&gKeyCode[1], rightKeyCode);
    atomic_store(&gKeyFlags[1], rightFlags & kShortcutModifiers);
    atomic_store(&gKeysEnabled, enabled);
}
