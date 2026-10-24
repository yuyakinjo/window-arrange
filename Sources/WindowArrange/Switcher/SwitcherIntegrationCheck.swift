#if DEBUG
import AppKit
import ApplicationServices
import ArrangementCore

/// Exercises enumeration, focus and real keyboard routing against one disposable child app.
@MainActor
enum SwitcherIntegrationCheck {
    private static var fixtureWindows: [NSWindow] = []
    static func fixture(prefix: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let bar = NSMenu(), item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        item.submenu = menu; bar.addItem(item); app.mainMenu = bar; app.windowsMenu = menu
        for suffix in ["A", "B", "Tab C", "Tab D"] {
            let window = NSWindow(contentRect: CGRect(x: 240, y: 240, width: 620, height: 410),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "\(prefix) \(suffix)"; window.isReleasedWhenClosed = false
            window.contentView = NSTextField(labelWithString: "Window Arrange switcher integration fixture · \(suffix)")
            window.tabbingMode = .disallowed
            fixtureWindows.append(window)
        }
        fixtureWindows[2].tabbingMode = .preferred; fixtureWindows[3].tabbingMode = .preferred
        fixtureWindows[2].tabbingIdentifier = prefix; fixtureWindows[3].tabbingIdentifier = prefix
        fixtureWindows[2].addTabbedWindow(fixtureWindows[3], ordered: .above)
        let untitled = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 317, height: 211),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        untitled.title = ""; untitled.tabbingMode = .disallowed
        let panel = NSPanel(contentRect: CGRect(x: 240, y: 240, width: 720, height: 84),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "\(prefix) Auxiliary"; panel.level = .floating
        let orderedOut = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        orderedOut.title = "\(prefix) Ordered out"; orderedOut.tabbingMode = .disallowed
        fixtureWindows.append(contentsOf: [untitled, panel, orderedOut])
        fixtureWindows.forEach { $0.orderFront(nil) }
        orderedOut.orderOut(nil)
        fixtureWindows[0].makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
    static func run(actionsOnly: Bool = false) async -> Int32 {
        let previous = NSWorkspace.shared.frontmostApplication
        let child = Process(), prefix = "WindowArrange-Switcher-\(UUID().uuidString)"
        let fixtureBundle = FileManager.default.temporaryDirectory.appendingPathComponent("SwitcherFixture-\(UUID().uuidString).app")
        let controller = WindowSwitcherController()
        var settings = SwitcherSettings(); settings.style = .icons; settings.release = .hold
        settings.summon = Shortcut(keyCode: 79, modifiers: 256 | 2048 | 4096, label: "⌃⌥⌘F18")
        var failure: Error?
        controller.onError = { failure = $0 }
        defer { controller.stop(); if child.isRunning { child.terminate() }; try? FileManager.default.removeItem(at: fixtureBundle); previous?.activate(options: []) }
        do {
            try AccessibilityService().requireAccess()
            let executable = fixtureBundle.appendingPathComponent("Contents/MacOS/WindowArrange")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, to: executable)
            let info: [String: Any] = ["CFBundleExecutable": "WindowArrange", "CFBundleIdentifier": "local.windowarrange.switcherfixture",
                "CFBundleName": "Window Arrange Fixture", "CFBundlePackageType": "APPL", "LSUIElement": false]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: fixtureBundle.appendingPathComponent("Contents/Info.plist"))
            let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--identifier", "local.windowarrange.switcherfixture", fixtureBundle.path]
            sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
            try sign.run(); sign.waitUntilExit()
            guard sign.terminationStatus == 0 else { throw ArrangeError("Fixture signing failed") }
            child.executableURL = executable
            child.arguments = ["--switcher-fixture", prefix]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.standardError
            try child.run()
            controller.configure(settings)
            guard controller.shortcutError == nil else { throw ArrangeError(controller.shortcutError!) }
            var inventory: [TrackedSwitcherWindow] = []
            for _ in 0..<40 {
                inventory = await controller.integrationInventory()
                if inventory.filter({ $0.info.title.hasPrefix(prefix) }).count >= 3 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let direct = AX.value(AXUIElementCreateApplication(child.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
            guard direct.contains(where: { AX.string($0, kAXRoleAttribute) == kAXWindowRole }) else {
                throw ArrangeError("検証用ウィンドウのAXWindow参照を取得できません。この環境では実機チェックを完了できません。")
            }
            guard let a = inventory.first(where: { $0.info.title == "\(prefix) A" }),
                  let b = inventory.first(where: { $0.info.title == "\(prefix) B" }), let axA = a.element else { throw ArrangeError("Fixture windows were not enumerated") }
            print("PASS: multiple windows of the same app are enumerated")
            let fixtureInventory = inventory.filter { $0.app.processIdentifier == child.processIdentifier }
            guard fixtureInventory.contains(where: { !$0.info.windowless && $0.info.title.isEmpty }),
                  !fixtureInventory.contains(where: { $0.info.title == "\(prefix) Auxiliary" }),
                  !fixtureInventory.contains(where: { $0.info.title == "\(prefix) Ordered out" }) else {
                throw ArrangeError("Untitled window / auxiliary panel / ordered-out surface eligibility mismatch")
            }
            print("PASS: untitled standard window is included; floating and ordered-out surfaces are excluded")
            // Exercise the other-Space acquisition route against a known window
            // without disturbing the user's current Space or needing a second one.
            let resolved: Bool = await withCheckedContinuation { continuation in
                let pid = child.processIdentifier, id = a.nativeID!
                DispatchQueue.global(qos: .userInitiated).async {
                    let resolver = SwitcherAXWindowResolver(), spaces = NativeSpaces()
                    for _ in 0..<10 {
                        if let ax = resolver.resolve(pid: pid, session: prefix, ids: [id], spaces: spaces)[id],
                           AX.string(ax, kAXTitleAttribute) == "\(prefix) A" {
                            continuation.resume(returning: true); return
                        }
                    }
                    continuation.resume(returning: false)
                }
            }
            guard resolved else { throw ArrangeError("Could not acquire the fixture's AX window through its WindowServer ID") }
            print("PASS: WindowServer ID resolves to a real AX window root")
            try await controller.integrationFocus(b)
            if !actionsOnly {
                try await controller.integrationFocus(a)
                print("PASS: exact focus between windows of the same app")
                try AX.setBool(axA, kAXMinimizedAttribute, true)
                try await Task.sleep(for: .milliseconds(400))
                inventory = await controller.integrationInventory()
                guard let minimized = inventory.first(where: { $0.info.id == a.info.id }), minimized.info.minimized else { throw ArrangeError("Minimized fixture missing from inventory") }
                try await controller.integrationFocus(minimized)
                guard !AX.bool(axA, kAXMinimizedAttribute) else { throw ArrangeError("Fixture remained minimized") }
                print("PASS: minimized windows stay listed and are restored when selected")
                a.app.hide(); try await Task.sleep(for: .milliseconds(250))
                inventory = await controller.integrationInventory()
                guard let hidden = inventory.first(where: { $0.info.id == a.info.id }), hidden.info.hidden else { throw ArrangeError("Hidden fixture missing from inventory") }
                try await controller.integrationFocus(hidden)
                print("PASS: hidden app is restored and the exact window is focused")
                let nativeTabs = inventory.filter { $0.info.title.hasPrefix(prefix) && $0.info.tabGroup != nil }
                guard nativeTabs.count >= 2 else { throw ArrangeError("Native tab group was not detected") }
                if let inactive = nativeTabs.first(where: { $0.inactiveTab }) { try await controller.integrationFocus(inactive) }
                print("PASS: native tabs are grouped and an inactive tab can be selected")
            }
            controller.show()
            try await Task.sleep(for: .milliseconds(350))
            guard controller.isOpen else { throw ArrangeError("Switcher did not open") }
            try controller.integrationRender(to: "/private/tmp/window-arrange-switcher-icons.png")
            controller.dismiss()
            print("PASS: overlay rendering and dismissal")
            settings.style = .thumbnails; settings.theme = .dark
            controller.configure(settings); controller.show()
            try await Task.sleep(for: .milliseconds(250))
            try controller.integrationRender(to: "/private/tmp/window-arrange-switcher-thumbnails.png")
            controller.dismiss()
            settings.style = .icons
            controller.configure(settings); controller.show()
            controller.select(a.info.id)
            guard controller.isOpen, controller.selectedID == a.info.id else { throw ArrangeError("Fixture A could not be selected") }
            postCommand(13)
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                inventory = await controller.integrationInventory()
                if !inventory.contains(where: { $0.info.id == a.info.id }) { break }
            }
            if let failure { throw failure }
            guard controller.integrationLastCommand == .closeWindow else { throw ArrangeError("Synthetic ⌘W did not reach the switcher keyboard handler") }
            guard controller.isOpen, !inventory.contains(where: { $0.info.id == a.info.id }),
                  inventory.contains(where: { $0.info.id == b.info.id }), !a.app.isTerminated else {
                let liveAX = AX.value(AXUIElementCreateApplication(child.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
                let server = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                throw ArrangeError("⌘W did not close only the selected fixture window (open: \(controller.isOpen), A: \(inventory.contains { $0.info.id == a.info.id }), B: \(inventory.contains { $0.info.id == b.info.id }), terminated: \(a.app.isTerminated), AX: \(liveAX.map { AX.string($0, kAXTitleAttribute) }), server A: \(server.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == a.nativeID }))")
            }
            guard controller.selectedID != a.info.id else { throw ArrangeError("Selection remained on the closed window") }
            // A held key must not close the next selection after reconciliation.
            controller.select(b.info.id)
            guard controller.isOpen, controller.selectedID == b.info.id else { throw ArrangeError("Fixture B could not be selected") }
            postCommand(13, repeating: true)
            try await Task.sleep(for: .milliseconds(250))
            inventory = await controller.integrationInventory()
            guard inventory.contains(where: { $0.info.id == b.info.id }) else { throw ArrangeError("Repeated ⌘W closed another window") }
            print("PASS: ⌘W closes the selected window, reconciles selection and ignores key repeat")
            guard controller.isOpen, controller.selectedID == b.info.id else { throw ArrangeError("Fixture B lost selection before quit") }
            postCommand(12)
            for _ in 0..<30 {
                if !child.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !child.isRunning, controller.isOpen else {
                throw ArrangeError("⌘Q did not terminate the selected fixture app (running: \(child.isRunning), open: \(controller.isOpen), command: \(String(describing: controller.integrationLastCommand)))")
            }
            print("PASS: ⌘Q requests normal termination of the selected app")
            controller.dismiss()
            if let failure { throw failure }
            return 0
        } catch { print("FAIL: \(error.localizedDescription)"); return 1 }
    }
    private static func postCommand(_ code: CGKeyCode, repeating: Bool = false) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = .maskCommand
            if down && repeating { event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event?.post(tap: .cghidEventTap)
        }
    }
}
#endif
