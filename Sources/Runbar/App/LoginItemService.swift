import ServiceManagement
import SwiftUI

/// Registers/unregisters Runbar as a login item via SMAppService.
@MainActor
final class LoginItemService: ObservableObject {
    static let shared = LoginItemService()

    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Fall through — isEnabled re-reads the actual state below.
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
