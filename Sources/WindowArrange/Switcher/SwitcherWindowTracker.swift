import AppKit
import ApplicationServices
import ArrangementCore

extension NSRunningApplication {
    var switcherAppID: String {
        bundleIdentifier ?? bundleURL?.standardizedFileURL.path ?? executableURL?.standardizedFileURL.path
            ?? "pid.\(processIdentifier):\(launchDate?.timeIntervalSince1970 ?? 0)"
    }
}

struct TrackedSwitcherWindow {
    var info: SwitcherWindow
    let app: NSRunningApplication
    let nativeID: UInt32?
    var element: AXUIElement?
    var tab: AXUIElement?
    var inactiveTab = false
}
struct SwitcherInventory {
    var windows: [TrackedSwitcherWindow]
    var visibleSpaces: Set<UInt64>
    var activeWindow: String?
    var cursorApp: String?
    var cursorWindows: Set<String>
}

/// AX queries run on one worker. Cache keys contain the launch date as well as the PID,
/// because WindowServer IDs and PIDs can both be reused after an app exits.
final class SwitcherScanner: @unchecked Sendable {
    // These system UI hosts expose panels (including desktop widgets) as windows.
    // Exclude the apps before AX/WindowServer discovery and the windowless fallback.
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.notificationcenterui"
    ]
    let spaces = NativeSpaces()
    private var elements: [String: [UInt32: AXUIElement]] = [:]
    private var subscriptions: SwitcherAXSubscriptions?

    func scan(displays: [DisplayRecord], mouse: CGPoint, frontPID: pid_t?, notify: (@Sendable () -> Void)? = nil) -> SwitcherInventory {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && !$0.isTerminated && $0.processIdentifier != getpid()
                && !Self.excludedBundleIDs.contains($0.bundleIdentifier ?? "")
        }
        let allSpaces = (try? spaces.spaces(includeFullscreen: true)) ?? []
        let visible = Set(((try? spaces.activeSpaces(includeFullscreen: true)) ?? []).map(\.runtimeID))
        let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreenIDs = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        var result: [TrackedSwitcherWindow] = [], aliveSessions = Set<String>(), activeWindow: String?
        var frontCursorApp: String?, cursorWindows = Set<String>()
        for app in apps {
            let pid = app.processIdentifier
            let appID = app.switcherAppID
            let session = "\(pid):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
            aliveSessions.insert(session)
            func key(_ id: UInt32) -> String { "\(session):\(id)" }
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.15)
            let axWindows = AX.value(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let focused = AX.element(axApp, kAXFocusedWindowAttribute)
            let focusedID = focused.flatMap { spaces.windowID($0) }
            var current: [UInt32: AXUIElement] = [:]
            for ax in axWindows {
                AXUIElementSetMessagingTimeout(ax, 0.15)
                guard let id = spaces.windowID(ax) else { continue }
                current[id] = ax
            }
            let appRaw = raw.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
            var cached = elements[session] ?? [:]
            let native = SwitcherWindowDiscovery.candidates(current: current, cached: &cached, server: appRaw,
                isValid: { id, ax in
                    var owner: pid_t = 0
                    return AXUIElementGetPid(ax, &owner) == .success && owner == pid
                        && self.spaces.windowID(ax) == id
                        && AX.string(ax, kAXRoleAttribute) == kAXWindowRole
                        && [kAXStandardWindowSubrole, kAXDialogSubrole, "AXSystemDialog"].contains(AX.string(ax, kAXSubroleAttribute))
                }, hasSpace: { !self.spaces.memberships($0).isEmpty })
            var retained: [UInt32: AXUIElement] = [:]
            for id in native {
                let entry = appRaw.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
                let ax = cached[id]
                let serverFrame = (entry?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
                guard let frame = ax.flatMap({ AX.frame($0) }) ?? serverFrame, frame.width > 1, frame.height > 1 else { continue }
                let memberships = Set(spaces.memberships(id))
                let space = allSpaces.first { memberships.contains($0.runtimeID) }
                let title = ax.map { AX.string($0, kAXTitleAttribute) }.flatMap { $0.isEmpty ? nil : $0 } ?? entry?[kCGWindowName as String] as? String ?? ""
                // macOS exposes its tile divider as a layer-zero WindowServer
                // window, but it is not an application window we can focus.
                if appID == "com.apple.WindowManager", title == "Tiling Handle Window" { continue }
                let info = SwitcherWindow(id: key(id), appID: appID, appName: app.localizedName ?? appID, title: title, frame: frame,
                    screenID: space?.record.displayID ?? Layout.display(for: frame, in: displays)?.id ?? "", spaces: memberships,
                    spaceIndex: space?.record.index ?? 0, minimized: ax.map { AX.bool($0, kAXMinimizedAttribute) } ?? false,
                    hidden: app.isHidden, fullscreen: ax.map { AX.bool($0, "AXFullScreen") } ?? (space?.record.label.hasPrefix("フルスクリーン") == true),
                    tabGroup: nil)
                retained[id] = ax
                result.append(TrackedSwitcherWindow(info: info, app: app, nativeID: id, element: ax))
                if pid == frontPID && id == focusedID { activeWindow = key(id) }
                if onScreenIDs.contains(id), !app.isHidden, !info.minimized, frame.contains(mouse) {
                    cursorWindows.insert(key(id))
                }
            }
            elements[session] = retained
            // Read only the native window chrome; never walk a web page or document tree.
            let appIndices = result.indices.filter { result[$0].app.processIdentifier == pid }
            var seenGroups = Set<String>()
            for index in appIndices {
                guard let ax = result[index].element, let group = nativeTabGroup(ax),
                      let tabs = AX.value(group, kAXChildrenAttribute) as? [AXUIElement], tabs.count > 1 else { continue }
                let buttons = tabs.filter { AX.string($0, kAXRoleAttribute) == kAXRadioButtonRole }
                guard buttons.count > 1 else { continue }
                let groupID = "\(session):tabs:\(CFHash(group))"
                guard seenGroups.insert(groupID).inserted else { continue }
                result[index].info.tabGroup = groupID
                for (offset, button) in buttons.enumerated() {
                    let title = AX.string(button, kAXTitleAttribute)
                    let selected = (AX.value(button, kAXValueAttribute) as? NSNumber)?.boolValue == true
                    if selected {
                        result[index].tab = button
                        continue
                    }
                    let matches = appIndices.filter { $0 != index && !title.isEmpty && result[$0].info.title == title }
                    if matches.count == 1, let match = matches.first {
                        result[match].info.tabGroup = groupID; result[match].tab = button; result[match].inactiveTab = true
                    } else {
                        var tab = result[index]
                        tab.info.id = "\(result[index].info.id):tab:\(offset):\(title)"
                        tab.info.title = title.isEmpty ? "タブ \(offset + 1)" : title
                        tab.tab = button; tab.inactiveTab = true
                        result.append(tab)
                    }
                }
            }
            if app.activationPolicy == .regular && !result.contains(where: { $0.app.processIdentifier == pid }) {
                result.append(TrackedSwitcherWindow(info: SwitcherWindow(id: "\(session):app", appID: appID, appName: app.localizedName ?? appID,
                    hidden: app.isHidden, windowless: true), app: app, nativeID: nil, element: nil))
            }
        }
        // Server order is front-to-back. It determines the app under the pointer,
        // whereas the window-under-pointer filter intentionally includes overlapping windows.
        for entry in raw {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let window = result.first(where: { $0.nativeID == id && cursorWindows.contains($0.info.id) }) else { continue }
            frontCursorApp = window.info.appID; break
        }
        elements = elements.filter { aliveSessions.contains($0.key) }
        let stack = Dictionary(uniqueKeysWithValues: raw.enumerated().compactMap { index, entry -> (UInt32, Int)? in
            (entry[kCGWindowNumber as String] as? NSNumber).map { ($0.uint32Value, index) }
        })
        result.sort { (stack[$0.nativeID ?? 0] ?? Int.max) < (stack[$1.nativeID ?? 0] ?? Int.max) }
        if let notify, subscriptions == nil { subscriptions = SwitcherAXSubscriptions(notify: notify) }
        subscriptions?.update(apps: apps, windows: result)
        return SwitcherInventory(windows: result, visibleSpaces: visible, activeWindow: activeWindow,
                                 cursorApp: frontCursorApp, cursorWindows: cursorWindows)
    }

    func stopObserving() { subscriptions?.stop(); subscriptions = nil }

    private func nativeTabGroup(_ window: AXUIElement) -> AXUIElement? {
        var level = [window]
        for _ in 0..<3 {
            var next: [AXUIElement] = []
            for item in level.prefix(32) {
                let role = AX.string(item, kAXRoleAttribute)
                if role == "AXTabGroup" { return item }
                if role == kAXWindowRole || role == kAXGroupRole || role == kAXToolbarRole {
                    next += AX.value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
                }
            }
            level = next
        }
        return nil
    }
}

@MainActor
final class SwitcherWindowTracker {
    private let worker = DispatchQueue(label: "local.windowarrange.switcher.inventory", qos: .userInitiated)
    private let scanner = SwitcherScanner()
    private var workspaceTokens: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var stopped = false
    private var running = false
    private var dirty = false
    private var history: [String: (created: UInt64, focused: UInt64)] = [:]
    private var clock: UInt64 = 0
    private var lastFocused: String?
    private(set) var inventory = SwitcherInventory(windows: [], visibleSpaces: [], activeWindow: nil, cursorApp: nil, cursorWindows: [])
    var onChange: (() -> Void)?
    var isSuspended: (() -> Bool)?

    func start() {
        stopped = false
        guard workspaceTokens.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedule() }
            })
        }
        schedule()
    }
    func stop() {
        stopped = true
        refreshTask?.cancel()
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceTokens.removeAll()
        let scanner = scanner
        worker.async { scanner.stopObserving() }
    }
    func schedule() {
        guard !stopped else { return }
        dirty = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }
    func refresh() async {
        guard !running else { dirty = true; return }
        guard !stopped, AXIsProcessTrusted(), isSuspended?() != true else { return }
        running = true; dirty = false
        let displays = AccessibilityService().displays()
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let scanner = scanner
        var next: SwitcherInventory = await withCheckedContinuation { continuation in
            worker.async { [weak self] in
                continuation.resume(returning: scanner.scan(displays: displays, mouse: mouse, frontPID: frontPID, notify: { [weak self] in
                    Task { @MainActor in self?.schedule() }
                }))
            }
        }
        guard !stopped else { running = false; return }
        let bootstrap = history.isEmpty && lastFocused == nil
        for index in next.windows.indices.sorted(by: { (next.windows[$0].nativeID ?? 0) < (next.windows[$1].nativeID ?? 0) }) {
            let id = next.windows[index].info.id
            if history[id] == nil { clock += 1; history[id] = (clock, bootstrap ? UInt64(next.windows.count - index) : 0) }
            next.windows[index].info.created = history[id]!.created
            next.windows[index].info.focused = history[id]!.focused
        }
        clock = max(clock, UInt64(next.windows.count))
        if let id = next.activeWindow, id != lastFocused {
            clock += 1; history[id]?.focused = clock; lastFocused = id; inventory.activeWindow = id
            if let index = next.windows.firstIndex(where: { $0.info.id == id }) { next.windows[index].info.focused = clock }
        }
        let live = Set(next.windows.map(\.info.id)); history = history.filter { live.contains($0.key) }
        inventory = next; running = false; onChange?()
        if dirty { schedule() }
    }
    func recordFocus(_ id: String) {
        clock += 1; history[id]?.focused = clock; lastFocused = id; inventory.activeWindow = id
        if let index = inventory.windows.firstIndex(where: { $0.info.id == id }) { inventory.windows[index].info.focused = clock }
    }
}

/// Registration and AX IPC stay on the scanner worker. The callback only queues a refresh;
/// its run-loop source is on main so it never races subscription dictionary mutations.
private final class SwitcherAXSubscriptions {
    private let notify: @Sendable () -> Void
    private var observers: [pid_t: AXObserver] = [:]
    private var sessions: [pid_t: Date] = [:]
    private var observedWindows: [pid_t: Set<String>] = [:]
    init(notify: @escaping @Sendable () -> Void) { self.notify = notify }
    func stop() {
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll(); observedWindows.removeAll(); sessions.removeAll()
    }
    func update(apps: [NSRunningApplication], windows: [TrackedSwitcherWindow]) {
        let launches = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0.launchDate ?? .distantPast) })
        for pid in observers.keys.filter({ launches[$0] == nil || launches[$0] != sessions[$0] }) {
            observedWindows.removeValue(forKey: pid); sessions.removeValue(forKey: pid)
            if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        }
        for app in apps where observers[app.processIdentifier] == nil {
            var observer: AXObserver?
            let status = AXObserverCreate(app.processIdentifier, { _, _, _, context in
                guard let context else { return }
                Unmanaged<SwitcherAXSubscriptions>.fromOpaque(context).takeUnretainedValue().notify()
            }, &observer)
            guard status == .success, let observer else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.15)
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                AXObserverAddNotification(observer, axApp, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            observers[app.processIdentifier] = observer; sessions[app.processIdentifier] = app.launchDate ?? .distantPast
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        let live = Set(windows.map(\.info.id))
        for window in windows {
            let pid = window.app.processIdentifier
            guard !window.info.id.contains(":tab:"), let element = window.element, let observer = observers[pid],
                  observedWindows[pid, default: []].insert(window.info.id).inserted else { continue }
            for name in [kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
                         kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        for pid in Array(observedWindows.keys) { observedWindows[pid] = observedWindows[pid]?.intersection(live) }
    }
}
