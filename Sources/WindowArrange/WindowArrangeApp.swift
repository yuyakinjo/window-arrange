import SwiftUI
import AppKit
import ApplicationServices
import ArrangementCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Also stay out of the Dock when launched directly with `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            IntegrationCheck.fixture(title: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--integration-check") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let status = await IntegrationCheck.run()
                fflush(stdout)
                exit(status)
            }
            app.run()
            return
        }
        #endif
        if CommandLine.arguments.contains("--diagnostics") {
            let spaces = NativeSpaces()
            let summary: [String: Any] = [
                "accessibilityTrusted": AXIsProcessTrusted(),
                "spacesSymbolsAvailable": spaces.available,
                "normalSpacesDetected": (try? spaces.spaces().count) ?? 0,
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

struct WindowArrangeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        MenuBarExtra("Window Arrange", systemImage: "rectangle.3.group") {
            MenuContent(openMainWindow: delegate.showMainWindow).environmentObject(delegate.model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Snapshotを保存") { Task { await delegate.model.capture() } }.disabled(delegate.model.busy)
            }
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    let openMainWindow: () -> Void
    var body: some View {
        Button("Window Arrangeを開く", action: openMainWindow)
        Divider()
        Button("Snapshotを保存") { Task { await model.capture() } }.disabled(model.busy)
        if let snapshot = model.selected {
            Button("「\(snapshot.name)」を復元") { Task { await model.restore(snapshot) } }.disabled(model.busy)
        }
        if !model.data.snapshots.isEmpty {
            Menu("Snapshotを選択") {
                ForEach(model.data.snapshots) { snapshot in
                    Button(snapshot.name) { model.select(snapshot.id) }
                }
            }
        }
        Divider()
        Button("終了") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
