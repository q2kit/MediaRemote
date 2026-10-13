import ServiceManagement

/// "Open at login" via the system Login Items (SMAppService).
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled = false
    /// Registered, but the user has to allow it in System Settings › General › Login Items.
    @Published private(set) var needsApproval = false
    @Published private(set) var error: String?

    private init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
