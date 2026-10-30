import CoreGraphics
import ArrangementCore

enum SpaceSwitchEvents {
    // Check physical key state, not the modifier flags attached to our synthetic shortcut.
    static var heldModifiers: CGEventFlags {
        let keys: [(CGKeyCode, CGEventFlags)] = [
            (54, .maskCommand), (55, .maskCommand), (56, .maskShift), (60, .maskShift),
            (58, .maskAlternate), (61, .maskAlternate), (59, .maskControl), (62, .maskControl)
        ]
        return keys.reduce(into: CGEventFlags()) { flags, pair in
            if CGEventSource.keyState(.hidSystemState, key: pair.0) { flags.formUnion(pair.1) }
        }
    }

    static func make(_ shortcut: SpaceSwitchShortcut, releasedFlags: CGEventFlags) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return nil }
        down.flags = CGEventFlags(rawValue: shortcut.modifiers).union(releasedFlags)
        // Do not leave Control/Option/Command marked as held in the combined session.
        up.flags = releasedFlags
        return [down, up]
    }
}
