import SwiftUI

@main
struct RunbarApp: App {
    @StateObject private var settingsModel: SettingsModel

    init() {
        let credentialStore = KeychainCredentialStore.production
        let authValidator = GitHubAuthValidator.live()

        let githubClient: GitHubClient?
        let githubInitializationError: String?
        do {
            let store = try SQLiteGitHubStore.production()
            githubClient = GitHubClient(store: store)
            githubInitializationError = nil
        } catch {
            githubClient = nil
            githubInitializationError = String(describing: error)
        }

        let repoDiscovery: RepoDiscovery?
        let discoveryInitializationError: String?
        if let githubClient {
            do {
                let store = try SQLiteStore.production()
                repoDiscovery = RepoDiscovery(
                    remoteDiscovery: GitHubRemoteRepoDiscovery(client: githubClient),
                    store: store
                )
                discoveryInitializationError = nil
            } catch {
                repoDiscovery = nil
                discoveryInitializationError = String(describing: error)
            }
        } else {
            repoDiscovery = nil
            discoveryInitializationError = githubInitializationError
        }

        _settingsModel = StateObject(
            wrappedValue: SettingsModel(
                credentialStore: credentialStore,
                authValidator: authValidator,
                repoDiscovery: repoDiscovery,
                discoveryInitializationError: discoveryInitializationError,
                githubClient: githubClient,
                githubInitializationError: githubInitializationError
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
