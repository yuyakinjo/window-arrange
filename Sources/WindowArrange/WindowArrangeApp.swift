import SwiftUI
import AppKit
import ApplicationServices
import ArrangementCore
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = AppModel()
    private var mainWindow: NSWindow?
    private var statusMenu: StatusMenuController?
    #if DEBUG
    private var developmentTermination: DispatchSourceSignal?
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Also stay out of the Dock when launched directly with `swift run`.
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let app = submenu("Window Arrange")
        let settings = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Window Arrangeを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("ファイル")
        let capture = NSMenuItem(title: "Snapshotを保存", action: #selector(captureSnapshot), keyEquivalent: "")
        capture.target = self
        file.addItem(capture)
        file.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("編集")
        for (title, selector, key) in [("取り消す", "undo:", "z"), ("やり直す", "redo:", "Z"),
                                       ("カット", "cut:", "x"), ("コピー", "copy:", "c"),
                                       ("ペースト", "paste:", "v"), ("すべてを選択", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let window = submenu("ウインドウ")
        window.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "拡大／縮小", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @objc private func openSettings() { model.section = "settings"; showMainWindow() }
    @objc private func captureSnapshot() { Task { await model.capture() } }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(captureSnapshot) || !model.busy
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.openMainWindow = { [weak self] in self?.showMainWindow() }
        statusMenu = StatusMenuController(state: { [weak self] in
            guard let model = self?.model else { return StatusMenuState() }
            return StatusMenuState(busy: model.busy, switcherEnabled: model.data.switcher.enabled,
                selected: model.selected, snapshots: model.data.snapshots,
                motionMonitoring: model.headMotion.monitoring, motionEnabled: model.headMotion.enabled,
                motionReady: model.headMotion.receiving && model.headMotion.calibrated)
        }, perform: { [weak self] action in self?.performMenuAction(action) },
           trackingChanged: { [weak self] tracking in self?.model.headMotion.setMenuTracking(tracking) })
        model.switcher.start()
        #if DEBUG
        if CommandLine.arguments.contains("--development") {
            // Let the Bun development runner request a normal app shutdown with SIGTERM.
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination.setEventHandler { NSApp.terminate(nil) }
            termination.resume()
            developmentTermination = termination
            if let section = UserDefaults.standard.string(forKey: "developmentSection"),
               ["snapshots", "shortcuts", "switcher", "airpods", "settings"].contains(section) {
                model.section = section
            }
            showMainWindow()
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.switcher.stop()
        model.headMotion.stop()
        statusMenu?.stop()
        #if DEBUG
        if CommandLine.arguments.contains("--development") {
            UserDefaults.standard.set(model.section, forKey: "developmentSection")
        }
        #endif
    }

    func showMainWindow() {
        if mainWindow == nil {
            // Create on demand so macOS 14 also launches without opening a window.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Window Arrange"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(model)
                .frame(minWidth: 960, minHeight: 640))
            window.contentMinSize = NSSize(width: 960, height: 640)
            window.center()
            #if DEBUG
            if CommandLine.arguments.contains("--development") {
                window.setFrameAutosaveName("developmentMainWindow")
            }
            #endif
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func performMenuAction(_ action: StatusMenuAction) {
        switch action {
        case .openWindow: showMainWindow()
        case .switchWindows: model.switcher.show()
        case .openAirPods: model.section = "airpods"; showMainWindow()
        case .toggleMotion: model.headMotion.setEnabled(!model.headMotion.enabled)
        case .stopMotion: model.headMotion.stop()
        case .capture: Task { await model.capture() }
        case .restore(let id):
            if let snapshot = model.data.snapshots.first(where: { $0.id == id }) {
                Task { await model.restore(snapshot) }
            }
        case .select(let id): model.select(id)
        case .quit: NSApp.terminate(nil)
        }
    }
}

@main
struct Launcher {
    static func main() {
        if CommandLine.arguments.contains("--restore-diagnostics") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do { try await RestoreDiagnostics.run(); fflush(stdout); exit(0) }
                catch { print(error.localizedDescription); fflush(stdout); exit(1) }
            }
            app.run()
            return
        }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--switcher-fixture"), CommandLine.arguments.indices.contains(index + 1) {
            SwitcherIntegrationCheck.fixture(prefix: CommandLine.arguments[index + 1]); return
        }
        if CommandLine.arguments.contains("--switcher-preview") {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do { try WindowSwitcherController.integrationPreview(); print("PASS: switcher previews rendered"); fflush(stdout); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); fflush(stdout); exit(1) }
            }
            app.run(); return
        }
        if CommandLine.arguments.contains("--switcher-check") || CommandLine.arguments.contains("--switcher-actions-check") {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let status = await SwitcherIntegrationCheck.run(actionsOnly: CommandLine.arguments.contains("--switcher-actions-check"))
                fflush(stdout); exit(status)
            }
            app.run(); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--restore-saved-window"), CommandLine.arguments.indices.contains(index + 1),
           let id = UUID(uuidString: CommandLine.arguments[index + 1]) {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do { try await RestoreDiagnostics.restoreSavedWindow(id); fflush(stdout); exit(0) }
                catch { print(error.localizedDescription); fflush(stdout); exit(1) }
            }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--test-window"), CommandLine.arguments.indices.contains(index + 1) {
            IntegrationCheck.fixture(title: CommandLine.arguments[index + 1], nativeMenu: !CommandLine.arguments.contains("--without-window-menu"))
            return
        }
        if CommandLine.arguments.contains("--integration-check") || CommandLine.arguments.contains("--native-tiling-check") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let status = CommandLine.arguments.contains("--native-tiling-check")
                    ? await NativeTilingIntegrationCheck.run() : await IntegrationCheck.run()
                fflush(stdout)
                exit(status)
            }
            app.run()
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--development"]) {
            WindowArrangeApp.main()
            return
        }
        #endif
        if CommandLine.arguments.contains("--diagnostics") {
            let spaces = NativeSpaces()
            let summary: [String: Any] = [
                "accessibilityTrusted": AXIsProcessTrusted(),
                "spacesSymbolsAvailable": spaces.available,
                "normalSpacesDetected": (try? spaces.spaces().count) ?? 0,
                "activeSpaceIndexes": (try? spaces.activeSpaces(includeFullscreen: true).map { $0.record.index }) ?? [],
                "physicalModifierFlags": SpaceSwitchEvents.heldModifiers.rawValue,
                "sessionModifierFlags": CGEventSource.flagsState(.combinedSessionState).rawValue,
                "externalDependencies": 0
            ]
            if let json = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: json, encoding: .utf8) { print(string) }
            return
        }
        if let unsupported = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
            print("Unsupported option: \(unsupported). Development checks require a debug build.")
            exit(64)
        }
        WindowArrangeApp.main()
    }
}

enum WindowArrangeApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSHostingView renders the existing management window; no extra SwiftUI
        // Settings scene is needed to keep the status-item app alive.
        withExtendedLifetime(delegate) { application.run() }
    }
}
