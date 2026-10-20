#if DEBUG
import AppKit
import ApplicationServices
import ArrangementCore

/// Development-only smoke check. Only its own disposable child window is modified.
@MainActor
enum IntegrationCheck {
    @MainActor private final class FixtureDelegate: NSObject, NSApplicationDelegate {
        let window: NSWindow
        init(window: NSWindow) { self.window = window }
        func applicationDidBecomeActive(_ notification: Notification) {
            window.makeKeyAndOrderFront(nil)
            Self.updateMenus()
        }
        static func updateMenus() {
            // Refresh validation without opening menus, including the enabled
            // state of Return to Previous Size after a native tile operation.
            NSApp.windowsMenu?.update()
            for item in NSApp.windowsMenu?.items ?? [] { item.submenu?.update() }
        }
    }
    static func fixture(title: String, nativeMenu: Bool = true) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menuBar = NSMenu()
        let appItem = NSMenuItem(title: "Window Arrange Test", action: nil, keyEquivalent: "")
        appItem.submenu = NSMenu(title: "Window Arrange Test")
        menuBar.addItem(appItem)
        if nativeMenu {
            let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
            let menu = NSMenu(title: "Window")
            menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            item.submenu = menu
            menuBar.addItem(item)
            app.windowsMenu = menu
        }
        app.mainMenu = menuBar
        let window = NSWindow(contentRect: CGRect(x: 180, y: 220, width: 640, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSTextField(labelWithString: "Window Arrange · disposable integration fixture")
        let delegate = FixtureDelegate(window: window)
        app.delegate = delegate
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in FixtureDelegate.updateMenus() }
        }
        window.makeKeyAndOrderFront(nil)
        app.run()
        timer.invalidate()
        withExtendedLifetime(delegate) {}
    }
    static func run() async -> Int32 {
        let child = Process()
        let title = "WindowArrange-Test-\(UUID().uuidString)"
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--test-window", title]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        defer { if child.isRunning { child.terminate() } }
        do {
            let service = AccessibilityService()
            try service.requireAccess()
            try child.run()
            let application = AXUIElementCreateApplication(child.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.3)
            var fixture: AXUIElement?
            for _ in 0..<60 {
                if let windows = AX.value(application, kAXWindowsAttribute) as? [AXUIElement],
                   let window = windows.first(where: { AX.string($0, kAXTitleAttribute) == title }) { fixture = window; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let window = fixture, let initial = AX.frame(window),
                  let display = Layout.display(for: initial, in: service.displays()) else { throw ArrangeError("Fixture window did not appear") }
            AXUIElementSetMessagingTimeout(window, 0.3)
            let target = Layout.frame(for: .left, window: initial, screen: display.visibleFrame)!
            try AX.setFrame(window, target)
            try await Task.sleep(for: .milliseconds(200))
            guard let actual = AX.frame(window), Layout.close(actual, target) else { throw ArrangeError("Tiling verification failed") }
            print("PASS: AX move and resize")
            try AX.setFrame(window, initial)
            try await Task.sleep(for: .milliseconds(200))
            guard let restored = AX.frame(window), Layout.close(restored, initial) else { throw ArrangeError("Frame restore verification failed") }
            print("PASS: exact frame restoration")
            try AX.setBool(window, kAXMinimizedAttribute, true)
            try await Task.sleep(for: .milliseconds(450))
            guard AX.bool(window, kAXMinimizedAttribute) else { throw ArrangeError("Minimization verification failed") }
            try AX.setBool(window, kAXMinimizedAttribute, false)
            try await Task.sleep(for: .milliseconds(450))
            guard !AX.bool(window, kAXMinimizedAttribute) else { throw ArrangeError("Deminimization verification failed") }
            print("PASS: minimize and restore")
            let spaces = NativeSpaces()
            guard let id = spaces.windowID(window), let original = spaces.spaceForWindow(id) else { throw ArrangeError("Fixture Space lookup failed") }
            let desktops = try spaces.spaces()
            guard let other = desktops.first(where: { $0.record.id != original.record.id }) else {
                print("SKIP: cross-Space check requires two existing normal Spaces")
                return 0
            }
            try await spaces.move(window: id, to: other.record.id)
            print("PASS: move to another Space with membership verification")
            let client = try AccessibilityPlacementClient(element: window, accessibility: service, spaces: spaces)
            try await WindowPlacementRestorer.restore(
                to: WindowPlacementTarget(frame: initial, displayID: display.id, spaceID: original.record.id), using: client)
            guard spaces.spaceForWindow(id)?.record.id == original.record.id,
                  let final = AX.frame(window), Layout.close(final, initial) else { throw ArrangeError("Space and frame restoration verification failed") }
            print("PASS: original Space and frame restoration")
            for otherDisplay in service.displays() where otherDisplay.id != display.id {
                guard let remoteSpace = desktops.last(where: { $0.record.displayID == otherDisplay.id }) else { continue }
                // Reproduce dragging a saved built-in-display window to another
                // monitor's second desktop before invoking the current restore order.
                let remoteFrame = Layout.remap(initial, from: display.visibleFrame, to: otherDisplay.visibleFrame)
                try AX.setFrame(window, remoteFrame)
                try await Task.sleep(for: .milliseconds(400))
                try await spaces.move(window: id, to: remoteSpace.record.id)
                print("SETUP: fixture is on another display's last Space")
                try await WindowPlacementRestorer.restore(
                    to: WindowPlacementTarget(frame: initial, displayID: display.id, spaceID: original.record.id), using: client)
                print("PASS: restore original display/Space/frame from another display's second desktop")
                // Also exercise the reverse path and same-display desktop changes.
                try await WindowPlacementRestorer.restore(
                    to: WindowPlacementTarget(frame: remoteFrame, displayID: otherDisplay.id, spaceID: remoteSpace.record.id), using: client)
                print("PASS: restore other display's saved Space/frame from original display")
                if let firstSpace = desktops.first(where: { $0.record.displayID == otherDisplay.id && $0.record.id != remoteSpace.record.id }) {
                    try await WindowPlacementRestorer.restore(
                        to: WindowPlacementTarget(frame: remoteFrame, displayID: otherDisplay.id, spaceID: firstSpace.record.id), using: client)
                    print("PASS: same-display restoration from second desktop to first desktop")
                }
                try await WindowPlacementRestorer.restore(
                    to: WindowPlacementTarget(frame: initial, displayID: display.id, spaceID: original.record.id), using: client)
                if let visibleSpace = desktops.first(where: { $0.record.displayID == otherDisplay.id && $0.record.id != remoteSpace.record.id }) {
                    try await verifyHiddenWindowEnumeration(window: window, windowID: id, childPID: child.processIdentifier,
                        spaces: spaces, savedSpace: original,
                        remoteDisplay: otherDisplay, remoteFrame: remoteFrame, remoteSpace: remoteSpace, visibleSpace: visibleSpace)
                }
            }
            return 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
    }
    private static func verifyHiddenWindowEnumeration(window: AXUIElement, windowID: UInt32, childPID: pid_t,
        spaces: NativeSpaces, savedSpace: LiveSpace,
        remoteDisplay: DisplayRecord, remoteFrame: CGRect, remoteSpace: LiveSpace, visibleSpace: LiveSpace) async throws {
        let before = try spaces.activeSpaces()
        var failure: Error?
        do {
            let provider: AccessibilityService.WindowProvider = { app in
                // Model Electron's actual behavior: omit the child window while
                // its Space is inactive. Other applications are read normally.
                if app.processIdentifier == childPID, let current = spaces.spaceForWindow(windowID) {
                    let active = (try? spaces.activeSpaces()) ?? []
                    if !active.contains(where: { $0.record.id == current.record.id }) { return [] }
                }
                return AX.value(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
            }
            let warm = AccessibilityService(windowProvider: provider)
            let captured = try await warm.windows(spaces: spaces).windows
            guard let savedWindow = captured.first(where: { $0.record.nativeID == windowID }) else { throw ArrangeError("Enumeration did not capture the test window") }
            let snapshot = Snapshot(name: "Hidden window regression", backend: .nativeSpaces, displays: warm.displays(), spaces: [savedSpace.record], windows: [savedWindow.record])
            let rawClient = try AccessibilityPlacementClient(element: window, accessibility: warm, spaces: spaces)
            try await WindowPlacementRestorer.restore(
                to: WindowPlacementTarget(frame: remoteFrame, displayID: remoteDisplay.id, spaceID: remoteSpace.record.id), using: rawClient)
            try await spaces.activate(visibleSpace.record.id)
            let retained = try await warm.restorationWindows(for: snapshot, spaces: spaces)
            guard retained.contains(where: { $0.record.nativeID == windowID }) else { throw ArrangeError("Cached window disappeared from restoration candidates") }
            print("PASS: snapshot reference survives omission from inactive-Space AXWindows")
            let cold = AccessibilityService(windowProvider: provider)
            let recovered = try await cold.restorationWindows(for: snapshot, spaces: spaces)
            let matches = WindowMatcher.match(saved: snapshot.windows, live: recovered.map(\.record))
            guard let match = matches[savedWindow.record.id], let target = recovered.first(where: { $0.record.id == match }) else {
                throw ArrangeError("Fresh service could not rediscover inactive-Space fixture")
            }
            _ = try await SnapshotWindowRestorer.restore(savedWindow.record, snapshot: snapshot, window: target, accessibility: cold, spaces: spaces)
            print("PASS: full rediscovery → matching → original display/Space/frame restoration after cache reset")
        } catch { failure = error }
        for space in before {
            do { try await spaces.activate(space.record.id) } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
}
#endif
