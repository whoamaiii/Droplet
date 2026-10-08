import Foundation
import ServiceManagement

/// "Open at login" through the system's login-item service, which users can
/// see and revoke in System Settings. Replaces the private KeepAlive agent.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var message: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = enabled
                ? "macOS didn't allow Droplet to open at login. You can add it in System Settings → General → Login Items."
                : "macOS didn't remove Droplet from login items. You can remove it in System Settings → General → Login Items."
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
