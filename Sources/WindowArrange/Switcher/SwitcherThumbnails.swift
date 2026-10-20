import AppKit
import ScreenCaptureKit

@MainActor
final class SwitcherThumbnails: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var permitted = CGPreflightScreenCaptureAccess()
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    private var generation = 0

    func requestPermission() {
        // Only an explicit settings button may request capture access.
        CGRequestScreenCaptureAccess()
        checkPermission()
        if !permitted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func checkPermission() {
        permitted = CGPreflightScreenCaptureAccess()
        if !permitted { images.removeAll(); message = nil }
    }
    func cancel() { generation += 1; task?.cancel(); task = nil }
    func load(_ windows: [TrackedSwitcherWindow]) {
        cancel(); checkPermission()
        guard permitted else { return }
        let current = generation
        let ids = Set(windows.filter { !$0.inactiveTab }.map(\.info.id)); images = images.filter { ids.contains($0.key) }
        task = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.message = nil
                for target in windows {
                    guard !Task.isCancelled, self.generation == current else { return }
                    guard !target.inactiveTab, let id = target.nativeID, let window = content.windows.first(where: { $0.windowID == id }),
                          window.frame.width > 0, window.frame.height > 0 else { continue }
                    let config = SCStreamConfiguration()
                    let scale = min(1, 540 / max(window.frame.width, window.frame.height))
                    config.width = max(2, Int(window.frame.width * scale)); config.height = max(2, Int(window.frame.height * scale))
                    config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                    do {
                        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                        guard !Task.isCancelled, self.generation == current else { return }
                        self.images[target.info.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    } catch {
                        // Minimized, protected and inactive-tab surfaces can be unavailable.
                        // Leave the application icon visible instead of failing the switcher.
                        guard !Task.isCancelled, self.generation == current else { return }
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.message = "画像を取得できません。アプリアイコンで表示しています。"
                self.checkPermission()
            }
        }
    }
}
