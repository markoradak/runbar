import SwiftUI

@main
struct RunbarApp: App {
    @StateObject private var settingsModel: SettingsModel

    init() {
        let credentialStore = KeychainCredentialStore.production
        let authValidator = GitHubAuthValidator.live()
        _settingsModel = StateObject(
            wrappedValue: SettingsModel(
                credentialStore: credentialStore,
                authValidator: authValidator
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
