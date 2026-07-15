import SwiftUI

@main
struct RunbarApp: App {
    @StateObject private var settingsModel: SettingsModel

    init() {
        let credentialStore = KeychainCredentialStore.production
        let authValidator = GitHubAuthValidator.live()

        let githubClient: GitHubClient?
        let repoDiscovery: RepoDiscovery?
        let pollScheduler: PollScheduler?
        let initializationError: String?
        do {
            let discoveryStore = try SQLiteStore.production()
            let githubStore = try SQLiteGitHubStore.production()
            let pollStore = try SQLitePollStore.production()
            let client = GitHubClient(store: githubStore)
            githubClient = client
            repoDiscovery = RepoDiscovery(
                remoteDiscovery: GitHubRemoteRepoDiscovery(client: client),
                store: discoveryStore
            )
            pollScheduler = PollScheduler(
                poller: GitHubRunPoller(client: client, store: pollStore),
                credentialProvider: KeychainPollCredentialProvider(credentialStore: credentialStore),
                recorder: pollStore
            )
            initializationError = nil
        } catch {
            githubClient = nil
            repoDiscovery = nil
            pollScheduler = nil
            initializationError = String(describing: error)
        }

        let model = SettingsModel(
            credentialStore: credentialStore,
            authValidator: authValidator,
            repoDiscovery: repoDiscovery,
            discoveryInitializationError: initializationError,
            githubClient: githubClient,
            githubInitializationError: initializationError,
            pollScheduler: pollScheduler
        )
        _settingsModel = StateObject(wrappedValue: model)
        Task { @MainActor in
            await model.loadIfNeeded()
        }
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
