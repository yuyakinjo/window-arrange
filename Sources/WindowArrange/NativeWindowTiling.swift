import AppKit
import ApplicationServices
import ArrangementCore

@MainActor
enum NativeWindowTiling {
    /// These are identifiers exposed by AppKit's menu items, not selectors we
    /// invoke. Unknown/changed identifiers simply use the coordinate fallback.
    static func identifier(for action: WindowAction, repeatMode: LayoutRepeatMode) -> String? {
        // Fill does not participate in directional size/display cycling.
        if action == .fill { return "_zoomFill:" }
        guard repeatMode == .none else { return nil }
        switch action {
        case .left: return "_zoomLeft:"
        case .right: return "_zoomRight:"
        case .top: return "_zoomTop:"
        case .bottom: return "_zoomBottom:"
        default: return nil
        }
    }

    /// Returns false only when native tiling is unavailable. After dispatching a
    /// press, never overwrite the OS's placement (including its tile margins).
    static func perform(_ action: WindowAction, repeatMode: LayoutRepeatMode, window: AXUIElement) throws -> Bool {
        guard #available(macOS 15, *), let identifier = identifier(for: action, repeatMode: repeatMode) else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let menuBar = AX.element(application, kAXMenuBarAttribute),
              let item = menuItem(in: menuBar, identifier: identifier),
              AX.bool(item, kAXEnabledAttribute) else { return false }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(item, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true else { return false }

        // Menu actions apply to the active window, so recheck after lookup.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = AX.element(application, kAXFocusedWindowAttribute), CFEqual(focused, window) else {
            throw ArrangeError("操作対象のウィンドウが切り替わったため、配置を中止しました。対象を前面にして再試行してください。")
        }
        AXUIElementSetMessagingTimeout(item, 0.5)
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        switch result {
        case .success: return true
        case .actionUnsupported, .notImplemented, .invalidUIElement: return false
        default:
            // cannotComplete can mean the app accepted the action but has not
            // replied yet. A coordinate fallback here would race native tiling.
            throw ArrangeError("macOS標準の配置を要求しましたが、アプリの応答を確認できませんでした（\(result.rawValue)）。配置を確認してから再試行してください。")
        }
    }

    private static func menuItem(in menuBar: AXUIElement, identifier: String) -> AXUIElement? {
        let deadline = ContinuousClock.now + .milliseconds(500)
        var remaining = 256
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth <= 6, remaining > 0, ContinuousClock.now < deadline else { return nil }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.25)
            let role = AX.string(element, kAXRoleAttribute)
            if role == kAXMenuItemRole, AX.string(element, kAXIdentifierAttribute) == identifier { return element }
            // Do not traverse unrelated accessibility trees or open any menus.
            guard [kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuItemRole].contains(role),
                  let children = AX.value(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            // Window is normally near the right end of the menu bar. Start
            // there so large File/Edit menus do not consume the lookup budget.
            for child in depth == 0 ? Array(children.reversed()) : children {
                if let found = find(child, depth: depth + 1) { return found }
                if remaining <= 0 || ContinuousClock.now >= deadline { break }
            }
            return nil
        }
        return find(menuBar, depth: 0)
    }
}
