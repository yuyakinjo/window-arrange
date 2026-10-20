import AppKit
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var changing = false
    @Published private(set) var error: String?
    init() { refresh() }
    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }
    func setEnabled(_ enabled: Bool) {
        guard !changing else { return }
        changing = true; error = nil
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { self.error = "自動起動を変更できませんでした：\(error.localizedDescription)" }
            refresh(); changing = false
        }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
