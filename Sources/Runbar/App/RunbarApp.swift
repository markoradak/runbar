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
        let gitWatcher: GitWatcher?
        let menuBarStore: (any MenuBarDataStoring)?
        let workflowJobsLoader: (any WorkflowJobsLoading)?
        let initializationError: String?
        do {
            let discoveryStore = try SQLiteStore.production()
            let githubStore = try SQLiteGitHubStore.production()
            let pollStore = try SQLitePollStore.production()
            let gitWatcherStore = try SQLiteGitWatcherStore.production()
            let menuStore = try SQLiteMenuBarStore.production()
            let client = GitHubClient(store: githubStore)
            let scheduler = PollScheduler(
                poller: GitHubRunPoller(client: client, store: pollStore),
                credentialProvider: KeychainPollCredentialProvider(credentialStore: credentialStore),
                recorder: pollStore
            )
            githubClient = client
            repoDiscovery = RepoDiscovery(
                remoteDiscovery: GitHubRemoteRepoDiscovery(client: client),
                store: discoveryStore
            )
            pollScheduler = scheduler
            gitWatcher = GitWatcher(localPushPoller: scheduler, recorder: gitWatcherStore)
            menuBarStore = menuStore
            workflowJobsLoader = GitHubWorkflowJobsLoader(client: client)
            initializationError = nil
        } catch {
            githubClient = nil
            repoDiscovery = nil
            pollScheduler = nil
            gitWatcher = nil
            menuBarStore = nil
            workflowJobsLoader = nil
            initializationError = String(describing: error)
        }

        let model = SettingsModel(
            credentialStore: credentialStore,
            authValidator: authValidator,
            repoDiscovery: repoDiscovery,
            discoveryInitializationError: initializationError,
            githubClient: githubClient,
            githubInitializationError: initializationError,
            pollScheduler: pollScheduler,
            gitWatcher: gitWatcher,
            menuBarStore: menuBarStore,
            workflowJobsLoader: workflowJobsLoader
        )
        _settingsModel = StateObject(wrappedValue: model)
        Task { @MainActor in
            await model.loadIfNeeded()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RunbarMenuView(model: settingsModel)
        } label: {
            MenuBarStatusLabel(state: settingsModel.menuBarIconState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: settingsModel)
        }
    }
}
