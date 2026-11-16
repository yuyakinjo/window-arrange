import AppKit
import ApplicationServices
import ArrangementCore
import CDockSwipe

/// Takes the Mission Control "Move left/right a space" shortcuts (⌃← / ⌃→ by default)
/// before macOS reads them, and switches with a synthetic Dock swipe instead, so there is no slide animation.
@MainActor
final class SpaceKeyController: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "instantSpaceKeys"); refresh() }
    }
    @Published private(set) var status = ""
    private let defaults: UserDefaults
    private var installed = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "instantSpaceKeys") as? Bool ?? true
        refresh()
    }

    /// Re-reads the shortcuts from System Settings and turns the tap on or off.
    /// Call when Accessibility permission or the app's activation changes.
    func refresh() {
        guard enabled else {
            ds_keys_configure(false, -1, 0, -1, 0)
            status = "オフ：macOS標準のアニメーションで切り替えます"
            return
        }
        guard AXIsProcessTrusted() else {
            ds_keys_configure(false, -1, 0, -1, 0)
            status = "アクセシビリティの許可が必要です"
            return
        }
        if !installed {
            installed = ds_keys_install { direction in
                // Keyboard tap thread: hand the work to the main thread and return at once.
                DispatchQueue.main.async { _ = ds_post_switch(direction) }
            }
        }
        guard installed else {
            status = "キー入力の監視を開始できませんでした"
            return
        }
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] ?? [:]
        let left = try? SpaceSwitchShortcut.resolve(.left, hotKeys: hotKeys)
        let right = try? SpaceSwitchShortcut.resolve(.right, hotKeys: hotKeys)
        ds_keys_configure(left != nil || right != nil,
                          Int32(left.map { Int($0.keyCode) } ?? -1), left?.modifiers ?? 0,
                          Int32(right.map { Int($0.keyCode) } ?? -1), right?.modifiers ?? 0)
        status = (left == nil && right == nil)
            ? "Mission Controlの「左／右の操作スペースに移動」が無効か、読み取れません"
            : "オン：\(Self.describe(left)) / \(Self.describe(right)) で高速に切り替えます"
    }

    private static func describe(_ shortcut: SpaceSwitchShortcut?) -> String {
        guard let shortcut else { return "—" }
        let flags = CGEventFlags(rawValue: shortcut.modifiers)
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        switch shortcut.keyCode {
        case 123: text += "←"
        case 124: text += "→"
        case 125: text += "↓"
        case 126: text += "↑"
        default: text += "キー\(shortcut.keyCode)"
        }
        return text
    }
}
