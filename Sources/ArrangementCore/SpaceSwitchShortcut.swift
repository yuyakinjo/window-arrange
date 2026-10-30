import Foundation

/// Reads the user's Mission Control shortcut overrides without changing macOS settings.
public struct SpaceSwitchShortcut: Equatable {
    public let keyCode: UInt16
    public let modifiers: UInt64

    public enum ResolutionError: LocalizedError {
        case disabled, unsupported
        public var errorDescription: String? {
            switch self {
            case .disabled: return "Mission Controlの「左／右の操作スペースに移動」が無効です。キーボードショートカットの設定で有効にしてください。"
            case .unsupported: return "Mission Controlの切り替えキーを読み取れませんでした。キーボードショートカットの設定を確認してください。"
            }
        }
    }

    public static func resolve(_ direction: HeadTiltDirection, hotKeys: [String: Any]) throws -> Self {
        let fallback = Self(keyCode: direction == .left ? 123 : 124, modifiers: 1 << 18)
        let id = direction == .left ? "79" : "81"
        guard let raw = hotKeys[id] else { return fallback }
        guard let entry = raw as? [String: Any] else { throw ResolutionError.unsupported }
        if let enabled = entry["enabled"] as? Bool, !enabled { throw ResolutionError.disabled }
        // An enabled-only override retains the system's default key combination.
        guard let rawValue = entry["value"] else { return fallback }
        guard let value = rawValue as? [String: Any], value["type"] as? String == "standard",
              let parameters = value["parameters"] as? [Int], parameters.count == 3,
              (0...127).contains(parameters[1]), parameters[2] >= 0,
              UInt64(parameters[2]) & ~UInt64(0xffff0000) == 0 else { throw ResolutionError.unsupported }
        return Self(keyCode: UInt16(parameters[1]), modifiers: UInt64(parameters[2]))
    }
}
