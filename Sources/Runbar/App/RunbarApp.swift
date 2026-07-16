import SwiftUI

@main
struct RunbarApp: App {
    @StateObject private var settingsModel: SettingsModel
    private let statusBarController: StatusBarController
    // Starts Sparkle's scheduled update checks for the app's lifetime.
    private let updaterService = UpdaterService.shared

    init() {
        let legacyCredentialStore = KeychainCredentialStore.production
        let githubAppAuthenticator = GitHubAppAuthClient.live()
        let githubAppSession = GitHubAppSession(
            store: KeychainGitHubAppCredentialStore.production,
            authenticator: githubAppAuthenticator
        )
        let authValidator = GitHubAuthValidator.live()
        let providerCredentialStore = ProviderCredentialStore.production

        let githubClient: GitHubClient?
        let repoDiscovery: RepoDiscovery?
        let pollScheduler: PollScheduler?
        let gitWatcher: GitWatcher?
        let menuBarStore: (any MenuBarDataStoring)?
        let workflowJobsLoader: (any WorkflowJobsLoading)?
        let providerMonitor: ExternalProviderMonitor?
        let initializationError: String?
        do {
            let discoveryStore = try SQLiteStore.production()
            let githubStore = try SQLiteGitHubStore.production()
            let pollStore = try SQLitePollStore.production()
            let gitWatcherStore = try SQLiteGitWatcherStore.production()
            let menuStore = try SQLiteMenuBarStore.production()
            let providerStore = try SQLiteProviderStore.production()
            let client = GitHubClient(store: githubStore)
            let scheduler = PollScheduler(
                poller: GitHubRunPoller(client: client, store: pollStore),
                credentialProvider: githubAppSession,
                recorder: pollStore
            )
            githubClient = client
            repoDiscovery = RepoDiscovery(
                remoteDiscovery: GitHubRemoteRepoDiscovery(client: client),
                store: discoveryStore
            )
            pollScheduler = scheduler
            let externalMonitor = ExternalProviderMonitor(
                clients: [VercelClient(), CloudflarePagesClient()],
                store: providerStore
            )
            providerMonitor = externalMonitor
            gitWatcher = GitWatcher(
                localPushPoller: CompositeLocalPushPoller(pollers: [scheduler, externalMonitor]),
                recorder: gitWatcherStore
            )
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
            providerMonitor = nil
            initializationError = String(describing: error)
        }

        let model = SettingsModel(
            credentialStore: legacyCredentialStore,
            credentialProvider: githubAppSession,
            authValidator: authValidator,
            githubAppAuthenticator: githubAppAuthenticator,
            githubAppSession: githubAppSession,
            repoDiscovery: repoDiscovery,
            discoveryInitializationError: initializationError,
            githubClient: githubClient,
            githubInitializationError: initializationError,
            pollScheduler: pollScheduler,
            gitWatcher: gitWatcher,
            menuBarStore: menuBarStore,
            workflowJobsLoader: workflowJobsLoader,
            providerCredentialStore: providerCredentialStore,
            providerMonitor: providerMonitor,
            notificationNotifier: SystemRunCompletionNotifier()
        )
        _settingsModel = StateObject(wrappedValue: model)
        statusBarController = StatusBarController(model: model)
        Task { @MainActor in
            await model.loadIfNeeded()
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(model: settingsModel)
        }
    }
}
