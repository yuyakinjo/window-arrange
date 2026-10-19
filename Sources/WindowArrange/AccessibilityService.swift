import AppKit
import ApplicationServices
import ArrangementCore

struct ArrangeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct LiveWindow {
    var record: WindowRecord
    let element: AXUIElement
}

enum AX {
    static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let result = value(element, key), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    static func string(_ element: AXUIElement, _ key: String) -> String { value(element, key) as? String ?? "" }
    static func bool(_ element: AXUIElement, _ key: String) -> Bool { value(element, key) as? Bool ?? false }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0, position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: position, size: size)
    }
    static func set(_ element: AXUIElement, _ key: String, _ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(element, key as CFString, value)
        guard result == .success else { throw ArrangeError("このアプリは操作に応答しませんでした（\(key): \(result.rawValue)）。") }
    }
    static func setBool(_ element: AXUIElement, _ key: String, _ value: Bool) throws {
        try set(element, key, value ? kCFBooleanTrue : kCFBooleanFalse)
    }
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) throws {
        var position = frame.origin, size = frame.size
        guard let p = AXValueCreate(.cgPoint, &position), let s = AXValueCreate(.cgSize, &size) else {
            throw ArrangeError("座標を変換できませんでした。")
        }
        // A smaller source display may constrain the first resize. Resize again after moving.
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        try set(element, kAXPositionAttribute, p)
        try set(element, kAXSizeAttribute, s)
        try set(element, kAXPositionAttribute, p)
    }
}

@MainActor
final class AccessibilityService {
    var trusted: Bool { AXIsProcessTrusted() }
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func requireAccess() throws {
        guard trusted else { throw ArrangeError("システム設定でWindow Arrangeのアクセシビリティを許可してください。") }
    }
    func displays() -> [DisplayRecord] {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let uuid = number.flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? String(number?.uint32Value ?? 0)
            func convert(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
            }
            return DisplayRecord(id: id, name: screen.localizedName, frame: convert(screen.frame), visibleFrame: convert(screen.visibleFrame))
        }
    }
    func windows(spaces: NativeSpaces? = nil) async throws -> (windows: [LiveWindow], skipped: Int) {
        try requireAccess()
        var result: [LiveWindow] = [], skipped = 0
        let displays = displays()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard let bundle = app.bundleIdentifier else { continue }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.25)
            guard let windows = AX.value(application, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for element in windows {
                AXUIElementSetMessagingTimeout(element, 0.25)
                guard AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else { continue }
                guard !AX.bool(element, "AXFullScreen"), let frame = AX.frame(element) else { skipped += 1; continue }
                var record = WindowRecord(appID: bundle, appName: app.localizedName ?? bundle,
                                          title: AX.string(element, kAXTitleAttribute), identifier: AX.string(element, kAXIdentifierAttribute),
                                          session: "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)",
                                          documentURL: AX.string(element, kAXDocumentAttribute),
                                          frame: frame, displayID: Layout.display(for: frame, in: displays)?.id ?? "",
                                          minimized: AX.bool(element, kAXMinimizedAttribute))
                if let spaces {
                    guard let windowID = spaces.windowID(element), let space = spaces.spaceForWindow(windowID) else { skipped += 1; continue }
                    record.nativeID = windowID; record.spaceID = space.record.id
                    record.displayID = displays.first(where: { $0.id == space.record.displayID })?.id ?? record.displayID
                }
                result.append(LiveWindow(record: record, element: element))
            }
            await Task.yield()
        }
        return (result, skipped)
    }
    func focusedWindow() throws -> AXUIElement {
        try requireAccess()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw ArrangeError("操作したいアプリを前面にしてショートカットを押してください。")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let window = AX.element(application, kAXFocusedWindowAttribute) else { throw ArrangeError("操作できるウィンドウがありません。") }
        AXUIElementSetMessagingTimeout(window, 0.25)
        return window
    }
    func perform(_ action: WindowAction) async throws {
        let window = try focusedWindow()
        if action == .minimize { try AX.setBool(window, kAXMinimizedAttribute, true); return }
        if action == .fullscreen { try AX.setBool(window, "AXFullScreen", !AX.bool(window, "AXFullScreen")); return }
        guard !AX.bool(window, "AXFullScreen") else { throw ArrangeError("フルスクリーンを解除してから配置してください。") }
        guard let frame = AX.frame(window) else { throw ArrangeError("ウィンドウの座標を取得できませんでした。") }
        let displays = displays()
        guard let display = Layout.display(for: frame, in: displays) else { return }
        let target: CGRect?
        if action == .nextDisplay, let index = displays.firstIndex(where: { $0.id == display.id }), displays.count > 1 {
            target = Layout.remap(frame, from: display.visibleFrame, to: displays[(index + 1) % displays.count].visibleFrame)
        } else { target = Layout.frame(for: action, window: frame, screen: display.visibleFrame) }
        guard let target else { throw ArrangeError("移動先のディスプレイがありません。") }
        try AX.setFrame(window, target)
        try await Task.sleep(for: .milliseconds(120))
        guard let actual = AX.frame(window), Layout.close(actual, target) else {
            throw ArrangeError("配置を要求しましたが、アプリの最小サイズなどの制約で指定どおりになりませんでした。")
        }
    }
}

