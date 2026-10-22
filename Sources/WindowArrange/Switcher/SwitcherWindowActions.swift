import AppKit
import ApplicationServices
import ArrangementCore

enum SwitcherWindowActions {
    /// Press the selected window's native close button without sending keys to the foreground app.
    static func close(_ target: TrackedSwitcherWindow) throws {
        guard !target.app.isTerminated, let nativeID = target.nativeID, !target.info.windowless else { return }
        let app = AXUIElementCreateApplication(target.app.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let spaces = NativeSpaces()
        let fresh = (AX.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first { spaces.windowID($0) == nativeID }
        guard let window = fresh ?? target.element else { throw ArrangeError("選択したウィンドウを取得できませんでした。") }
        AXUIElementSetMessagingTimeout(window, 0.2)
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == target.app.processIdentifier,
              spaces.windowID(window) == nativeID else { throw ArrangeError("選択したウィンドウはすでに閉じられています。") }
        if let tab = target.tab {
            AXUIElementSetMessagingTimeout(tab, 0.2)
            if !AX.bool(tab, kAXValueAttribute) {
                guard AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success,
                      AX.bool(tab, kAXValueAttribute) else { throw ArrangeError("閉じるタブを選択できませんでした。") }
            }
        }
        guard let button = AX.element(window, kAXCloseButtonAttribute) else {
            throw ArrangeError("「\(target.info.title)」には操作できる閉じるボタンがありません。")
        }
        AXUIElementSetMessagingTimeout(button, 0.2)
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw ArrangeError("「\(target.info.title)」を閉じることができませんでした。")
        }
    }
}
