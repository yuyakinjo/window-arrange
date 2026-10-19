#if DEBUG
import AppKit
import ApplicationServices
import ArrangementCore

/// Development-only smoke check. Only its own disposable child window is modified.
@MainActor
enum IntegrationCheck {
    static func fixture(title: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 180, y: 220, width: 640, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSTextField(labelWithString: "Window Arrange · disposable integration fixture")
        window.makeKeyAndOrderFront(nil)
        app.run()
        withExtendedLifetime(window) {}
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
            try await spaces.move(window: id, to: original.record.id)
            try AX.setFrame(window, initial)
            try await Task.sleep(for: .milliseconds(200))
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
                do {
                    try await spaces.move(window: id, to: original.record.id)
                    try AX.setFrame(window, initial)
                    try await Task.sleep(for: .milliseconds(500))
                    guard spaces.spaceForWindow(id)?.record.id == original.record.id,
                          let frame = AX.frame(window), Layout.close(frame, initial) else {
                        throw ArrangeError("Cross-display Space/frame mismatch")
                    }
                    print("PASS: restore from another display's second desktop")
                } catch {
                    let frame = AX.frame(window)
                    print("TRACE: original order failed; physical display matches destination: \(frame.flatMap { Layout.display(for: $0, in: service.displays()) }?.id == display.id); Space matches destination: \(spaces.spaceForWindow(id)?.record.id == original.record.id)")
                    throw error
                }
            }
            return 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
    }
}
#endif
