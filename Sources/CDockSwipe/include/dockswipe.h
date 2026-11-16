#ifndef DOCKSWIPE_H
#define DOCKSWIPE_H

// Adapted from Interspace (https://github.com/cnrad/interspace, MIT). See dockswipe.c.

#include <stdbool.h>

typedef enum {
    DSDirectionLeft = 0,  /* towards the space with the lower index */
    DSDirectionRight = 1, /* towards the space with the higher index */
} DSDirection;

/** Posts a synthetic Dock swipe that makes the Dock switch one space with no visible animation. */
bool ds_post_switch(DSDirection direction);

/**
 * Called for a press of the shortcut for the space to the left or to the right.
 * It runs on the thread of the keyboard tap, not on the main thread, and must return at once.
 */
typedef void (*DSKeyHandler)(DSDirection direction);

/**
 * Installs the keyboard tap, on a thread of its own. Needs Accessibility permission. Safe to call again.
 * The tap does nothing until `ds_keys_configure` turns it on.
 */
bool ds_keys_install(DSKeyHandler handler);

/**
 * Sets the two shortcuts: a virtual key code and the modifier flags (shift, control, option, command only).
 * A key code below 0 turns that direction off. With `enabled` false every key passes through.
 * A press that matches is swallowed, so macOS does not start its own transition, and the handler is called.
 */
void ds_keys_configure(bool enabled, int leftKeyCode, unsigned long long leftFlags,
                       int rightKeyCode, unsigned long long rightFlags);

/** True on macOS 27+, where synthetic swipes must carry the raw IOHID payload. */
bool ds_requires_event_augmentation(void);

#endif
