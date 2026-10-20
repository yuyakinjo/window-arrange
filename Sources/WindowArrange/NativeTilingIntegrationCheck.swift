#if DEBUG
import AppKit
import ApplicationServices
import ArrangementCore

/// Exercises the real command path against disposable child windows only.
@MainActor
enum NativeTilingIntegrationCheck {
    static func run() async -> Int32 {
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(options: []) }
        do {
            let service = AccessibilityService()
            try service.requireAccess()
            guard #available(macOS 15, *) else { print("SKIP: native tiling requires macOS 15"); return 0 }
            try await withFixture(nativeMenu: true) { application, window in
                guard let initial = AX.frame(window), let display = Layout.display(for: initial, in: service.displays()) else {
                    throw ArrangeError("Fixture display unavailable")
                }
                for action in [WindowAction.left, .right, .top, .bottom, .fill] {
                    try await service.perform(action)
                    let target = Layout.frame(for: action, window: initial, screen: display.visibleFrame)!
                    var actual: CGRect?
                    var previous: CGRect?
                    var stableSamples = 0
                    for _ in 0..<30 {
                        try await Task.sleep(for: .milliseconds(100))
                        if let frame = AX.frame(window), Layout.close(frame, target, tolerance: 32) {
                            stableSamples = previous.map { Layout.close($0, frame, tolerance: 1) } == true ? stableSamples + 1 : 1
                            previous = frame
                            if stableSamples >= 3 { actual = frame; break }
                        } else { stableSamples = 0; previous = nil }
                    }
                    guard let actual, Layout.close(actual, target, tolerance: 32) else {
                        throw ArrangeError("Native placement failed for \(action): \(String(describing: actual))")
                    }
                    // Coordinate assignment alone does not establish native
                    // tiling state or enable Return to Previous Size.
                    guard let menuBar = AX.element(application, kAXMenuBarAttribute), menuItemEnabled(in: menuBar, identifier: "_zoomUntile:") else {
                        throw ArrangeError("Native tile state missing for \(action)")
                    }
                    guard !AX.bool(window, "AXFullScreen") else { throw ArrangeError("Native placement entered full screen") }
                    try await Task.sleep(for: .milliseconds(350))
                    guard let settled = AX.frame(window), Layout.close(settled, actual) else {
                        throw ArrangeError("Native placement was overwritten for \(action)")
                    }
                    print("PASS: native \(action), tile state and preserved margins (\(actual))")
                }
                for mode in [LayoutRepeatMode.cycle, .displays] {
                    guard try !NativeWindowTiling.perform(.left, repeatMode: mode, window: window) else {
                        throw ArrangeError("Native menu intercepted \(mode)")
                    }
                }
                guard try !NativeWindowTiling.perform(.topLeft, repeatMode: .none, window: window) else {
                    throw ArrangeError("Native menu intercepted quarter placement")
                }
                try AX.setFrame(window, initial)
                for _ in 0..<2 {
                    let before = AX.frame(window)!
                    let expected = Layout.target(for: .left, window: before, displays: service.displays(), repeatMode: .cycle)!
                    try await service.perform(.left, repeatMode: .cycle)
                    guard let actual = AX.frame(window), Layout.close(actual, expected.frame) else {
                        throw ArrangeError("Size cycling regression")
                    }
                }
                print("PASS: cycle modes bypass native menus; 1/2 → 2/3 preserved")
                for mode in [LayoutRepeatMode.cycle, .displays] {
                    try AX.setFrame(window, initial)
                    try await Task.sleep(for: .milliseconds(150))
                    guard try NativeWindowTiling.perform(.fill, repeatMode: mode, window: window) else {
                        throw ArrangeError("Native Fill unavailable in \(mode)")
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    guard let actual = AX.frame(window), Layout.close(actual, display.visibleFrame, tolerance: 32),
                          !AX.bool(window, "AXFullScreen"),
                          let menuBar = AX.element(application, kAXMenuBarAttribute), menuItemEnabled(in: menuBar, identifier: "_zoomUntile:") else {
                        throw ArrangeError("Native Fill failed in \(mode)")
                    }
                    print("PASS: native Fill in \(mode)")
                }
            }
            try await withFixture(nativeMenu: false) { _, window in
                guard let initial = AX.frame(window), let display = Layout.display(for: initial, in: service.displays()) else {
                    throw ArrangeError("Fallback fixture display unavailable")
                }
                for action in [WindowAction.left, .right, .top, .bottom, .fill] {
                    guard try !NativeWindowTiling.perform(action, repeatMode: .none, window: window) else {
                        throw ArrangeError("Menu-less fixture unexpectedly used native tiling")
                    }
                    try await service.perform(action)
                    guard let actual = AX.frame(window), Layout.close(actual, Layout.frame(for: action, window: initial, screen: display.visibleFrame)!) else {
                        throw ArrangeError("Coordinate fallback failed for \(action)")
                    }
                    print("PASS: coordinate fallback for \(action) without a Window menu")
                }
            }
            return 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
    }

    private static func withFixture(nativeMenu: Bool, check: (AXUIElement, AXUIElement) async throws -> Void) async throws {
        let child = Process()
        let title = "WindowArrange-Native-Test-\(UUID().uuidString)"
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--test-window", title] + (nativeMenu ? [] : ["--without-window-menu"])
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        defer { if child.isRunning { child.terminate() } }
        try child.run()
        let application = AXUIElementCreateApplication(child.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var fixture: AXUIElement?
        for _ in 0..<60 {
            if let windows = AX.value(application, kAXWindowsAttribute) as? [AXUIElement],
               let candidate = windows.first(where: { AX.string($0, kAXTitleAttribute) == title }) { fixture = candidate; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let window = fixture, let app = NSRunningApplication(processIdentifier: child.processIdentifier) else {
            throw ArrangeError("Fixture did not appear")
        }
        AXUIElementSetMessagingTimeout(window, 0.3)
        app.activate(options: [])
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier,
               let focused = AX.element(application, kAXFocusedWindowAttribute), CFEqual(focused, window) {
                // Activation and menu validation can complete on different
                // run-loop turns. Do not mistake initial disabled items for
                // an app without native tiling support.
                if !nativeMenu || AX.element(application, kAXMenuBarAttribute).map({ menuItemEnabled(in: $0, identifier: "_zoomLeft:") }) == true {
                    try await check(application, window)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ArrangeError("Fixture did not become active")
    }

    private static func menuItemEnabled(in element: AXUIElement, identifier: String) -> Bool {
        if AX.string(element, kAXIdentifierAttribute) == identifier { return AX.bool(element, kAXEnabledAttribute) }
        return (AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains { menuItemEnabled(in: $0, identifier: identifier) }
    }
}
#endif
