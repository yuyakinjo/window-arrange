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
    typealias WindowProvider = @MainActor (NSRunningApplication) -> [AXUIElement]
    private let windowProvider: WindowProvider?
    private var referenceCache = WindowReferenceCache<AXUIElement>()
    init(windowProvider: WindowProvider? = nil) { self.windowProvider = windowProvider }
    private func session(_ app: NSRunningApplication) -> String { "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)" }
    private var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleIdentifier != nil }
    }
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
    func serverWindows(spaces: NativeSpaces) -> [WindowRecord] {
        let apps = Dictionary(uniqueKeysWithValues: applications.map { ($0.processIdentifier, $0) })
        let displays = displays()
        return (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? NSNumber, let app = apps[pid.int32Value],
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 80, frame.height >= 60,
                  let space = spaces.spaceForWindow(id) else { return nil }
            return WindowRecord(appID: app.bundleIdentifier!, appName: app.localizedName ?? app.bundleIdentifier!,
                                title: info[kCGWindowName as String] as? String ?? "", session: session(app), nativeID: id,
                                frame: frame, displayID: displays.first(where: { $0.id == space.record.displayID })?.id ?? Layout.display(for: frame, in: displays)?.id ?? "",
                                spaceID: space.record.id)
        }
    }
    func windows(spaces: NativeSpaces? = nil, requireKnownSpace: Bool = true) async throws -> (windows: [LiveWindow], skipped: Int) {
        try requireAccess()
        var result: [LiveWindow] = [], skipped = 0
        let displays = displays()
        let apps = applications
        let server = spaces.map { serverWindows(spaces: $0) } ?? []
        let alive = Set(server.compactMap { window -> WindowReferenceKey? in
            window.nativeID.map { WindowReferenceKey(appID: window.appID, session: window.session, windowID: $0) }
        })
        var visible: [WindowReferenceKey: AXUIElement] = [:]
        var ordinary: [(NSRunningApplication, AXUIElement)] = []
        for app in apps {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.25)
            for element in windowProvider?(app) ?? (AX.value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []) {
                if let id = spaces?.windowID(element) {
                    visible[WindowReferenceKey(appID: app.bundleIdentifier!, session: session(app), windowID: id)] = element
                } else { ordinary.append((app, element)) }
            }
            await Task.yield()
        }
        let cached = referenceCache.merge(visible: visible, alive: alive)
        for (key, element) in cached {
            guard let app = apps.first(where: { $0.bundleIdentifier == key.appID && session($0) == key.session }),
                  spaces?.windowID(element) == key.windowID else { referenceCache.remove(key); continue }
            ordinary.append((app, element))
        }
        // A WindowServer query can transiently omit a visible window. Keep its
        // direct AX result for this call even if it cannot enter the cache yet.
        for (key, element) in visible where cached[key] == nil {
            if let app = apps.first(where: { $0.bundleIdentifier == key.appID && session($0) == key.session }) { ordinary.append((app, element)) }
        }
        for (app, element) in ordinary {
            let bundle = app.bundleIdentifier!
            AXUIElementSetMessagingTimeout(element, 0.25)
            guard AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else { continue }
            guard !AX.bool(element, "AXFullScreen"), let frame = AX.frame(element) else { skipped += 1; continue }
            var record = WindowRecord(appID: bundle, appName: app.localizedName ?? bundle,
                                      title: AX.string(element, kAXTitleAttribute), identifier: AX.string(element, kAXIdentifierAttribute),
                                      session: session(app),
                                      documentURL: AX.string(element, kAXDocumentAttribute),
                                      frame: frame, displayID: Layout.display(for: frame, in: displays)?.id ?? "",
                                      minimized: AX.bool(element, kAXMinimizedAttribute))
            if let spaces {
                guard let windowID = spaces.windowID(element) else { skipped += 1; continue }
                record.nativeID = windowID
                if let space = spaces.spaceForWindow(windowID) {
                    record.spaceID = space.record.id
                    record.displayID = displays.first(where: { $0.id == space.record.displayID })?.id ?? record.displayID
                } else if requireKnownSpace { skipped += 1; continue }
            }
            result.append(LiveWindow(record: record, element: element))
        }
        return (result, skipped)
    }
    func restorationWindows(for snapshot: Snapshot, spaces: NativeSpaces?) async throws -> [LiveWindow] {
        var live = try await windows(spaces: spaces, requireKnownSpace: false).windows
        guard let spaces else { return live }
        let knownIDs = Set(live.compactMap { $0.record.nativeID })
        let hidden = serverWindows(spaces: spaces).filter { !knownIDs.contains($0.nativeID ?? 0) }
        let candidates = live.map(\.record) + hidden
        let matches = WindowMatcher.match(saved: snapshot.windows, live: candidates)
        let needed = hidden.filter { matches.values.contains($0.id) }
        guard !needed.isEmpty else { return live }
        // A fresh app process has no cached AX references yet. Temporarily show
        // only the relevant Spaces to acquire them, then restore visible desktops.
        let previous = try spaces.activeSpaces()
        let neededSpaces = Set(needed.compactMap(\.spaceID))
        var failure: Error?
        do {
            for uuid in neededSpaces.sorted() {
                try await spaces.activate(uuid)
                let ids = Set(needed.filter { $0.spaceID == uuid }.compactMap(\.nativeID))
                var acquired = false
                for _ in 0..<15 {
                    live = try await windows(spaces: spaces, requireKnownSpace: false).windows
                    if ids.isSubset(of: Set(live.compactMap { $0.record.nativeID })) { acquired = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard acquired else { throw ArrangeError("対象のSpaceを表示しましたが、アプリからウィンドウ参照を取得できませんでした。対象ウィンドウを一度クリックしてから再試行してください。") }
            }
        } catch { failure = error }
        for space in previous {
            do { try await spaces.activate(space.record.id) }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
        return try await windows(spaces: spaces, requireKnownSpace: false).windows
    }
    func focusedWindow() throws -> AXUIElement {
        try requireAccess()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ArrangeError("操作したいアプリを前面にしてショートカットを押してください。")
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw ArrangeError("Window Arrange自身のウィンドウは操作対象外です。操作したい別のアプリを前面にしてショートカットを押してください。")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let window = AX.element(application, kAXFocusedWindowAttribute) else { throw ArrangeError("操作できるウィンドウがありません。") }
        AXUIElementSetMessagingTimeout(window, 0.25)
        return window
    }
    func perform(_ action: WindowAction, repeatMode: LayoutRepeatMode = .none) async throws {
        let window = try focusedWindow()
        if action == .minimize { try AX.setBool(window, kAXMinimizedAttribute, true); return }
        if action == .fullscreen { try AX.setBool(window, "AXFullScreen", !AX.bool(window, "AXFullScreen")); return }
        guard !AX.bool(window, "AXFullScreen") else { throw ArrangeError("フルスクリーンを解除してから配置してください。") }
        guard let frame = AX.frame(window) else { throw ArrangeError("ウィンドウの座標を取得できませんでした。") }
        let displays = displays()
        guard let display = Layout.display(for: frame, in: displays) else { return }
        guard let target = Layout.target(for: action, window: frame, displays: displays, repeatMode: repeatMode) else {
            throw ArrangeError("移動先のディスプレイがありません。")
        }
        if target.displayID != display.id {
            let client = try AccessibilityPlacementClient(element: window, accessibility: self, spaces: nil)
            try await WindowPlacementRestorer.restore(to: target, using: client)
            return
        }
        try AX.setFrame(window, target.frame)
        try await Task.sleep(for: .milliseconds(120))
        guard let actual = AX.frame(window), Layout.close(actual, target.frame) else {
            throw ArrangeError("配置を要求しましたが、アプリの最小サイズなどの制約で指定どおりになりませんでした。")
        }
    }
}

