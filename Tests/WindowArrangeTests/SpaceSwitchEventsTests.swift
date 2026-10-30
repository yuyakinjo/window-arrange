import Testing
import CoreGraphics
import ArrangementCore
@testable import WindowArrange

struct SpaceSwitchEventsTests {
    @Test func shortcutReleasesSyntheticModifiers() throws {
        let shortcut = try SpaceSwitchShortcut.resolve(.left, hotKeys: [
            "79": ["enabled": true, "value": ["type": "standard", "parameters": [105, 34, 262144]]]
        ])
        let events = try #require(SpaceSwitchEvents.make(shortcut, releasedFlags: []))
        #expect(events.count == 2)
        #expect(events[0].type == .keyDown)
        #expect(events[0].flags.contains(.maskControl))
        #expect(events[0].getIntegerValueField(.keyboardEventKeycode) == 34)
        #expect(events[1].type == .keyUp)
        #expect(events[1].getIntegerValueField(.keyboardEventKeycode) == 34)
        #expect(events[1].flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand]).isEmpty)
    }

    @Test func capsLockIsPreservedWhileShortcutModifiersAreReleased() throws {
        let shortcut = try SpaceSwitchShortcut.resolve(.right, hotKeys: [:])
        let events = try #require(SpaceSwitchEvents.make(shortcut, releasedFlags: .maskAlphaShift))
        #expect(events[0].flags.contains(.maskAlphaShift))
        #expect(events[1].flags.contains(.maskAlphaShift))
        #expect(!events[1].flags.contains(.maskControl))
    }
}
