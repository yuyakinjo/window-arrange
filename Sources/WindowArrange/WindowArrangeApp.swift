import SwiftUI
import AppKit
import ApplicationServices
import ArrangementCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
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
        WindowArrangeApp.main()
    }
}

struct WindowArrangeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Window Arrange", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1140, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Snapshotを保存") { Task { await model.capture() } }.disabled(model.busy)
            }
        }
        MenuBarExtra("Window Arrange", systemImage: "rectangle.3.group") {
            MenuContent().environmentObject(model)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Window Arrangeを開く") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
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
