import SwiftUI

@main
struct RunbarApp: App {
    @StateObject private var settingsModel: SettingsModel

    init() {
        let credentialStore = KeychainCredentialStore.production
        let authValidator = GitHubAuthValidator.live()

        let repoDiscovery: RepoDiscovery?
        let discoveryInitializationError: String?
        do {
            let store = try SQLiteStore.production()
            repoDiscovery = RepoDiscovery(store: store)
            discoveryInitializationError = nil
        } catch {
            repoDiscovery = nil
            discoveryInitializationError = String(describing: error)
        }

        _settingsModel = StateObject(
            wrappedValue: SettingsModel(
                credentialStore: credentialStore,
                authValidator: authValidator,
                repoDiscovery: repoDiscovery,
                discoveryInitializationError: discoveryInitializationError
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: settingsModel)
        } label: {
            Label("Runbar", systemImage: settingsModel.menuBarSystemImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: settingsModel)
        }
    }
}
