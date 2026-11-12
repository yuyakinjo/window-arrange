import AppKit

/// Synthesised media keys. macOS draws its own brightness and volume overlay for these,
/// so an edge slide looks exactly like pressing the keys on the keyboard.
enum MediaKey: Int32 {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3

    var title: String {
        switch self {
        case .volumeUp: return "音量を上げる"
        case .volumeDown: return "音量を下げる"
        case .brightnessUp: return "明るさを上げる"
        case .brightnessDown: return "明るさを下げる"
        }
    }
}

enum MediaKeyEvents {
    /// Posts one press. `fine` uses the quarter-step modifiers macOS applies to the keys.
    @discardableResult
    static func post(_ key: MediaKey, fine: Bool = false) -> Bool {
        let flags: NSEvent.ModifierFlags = fine ? [.shift, .option] : []
        for down in [true, false] {
            let data1 = (Int(key.rawValue) << 16) | (down ? 0xA00 : 0xB00)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                                 context: nil, subtype: 8, data1: data1, data2: -1),
                  let cgEvent = event.cgEvent else { return false }
            cgEvent.post(tap: .cghidEventTap)
        }
        return true
    }
}
