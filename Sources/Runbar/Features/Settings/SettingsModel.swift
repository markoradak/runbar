import AppKit
import Foundation
import os

enum SettingsAuthState: Equatable {
    case loading
    case signedOut
    case validating
    case authenticated(login: String)
    case failed(message: String, hasStoredCredential: Bool)
}

enum RepositoryDiscoveryState: Equatable {
    case idle
    case refreshing
    case loaded
    case failed(message: String)
}

enum ETagVerificationState: Equatable {
    case idle
    case running(completedRequests: Int)
    case succeeded
    case failed(message: String)
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tokenInput = ""
    @Published var verificationRepositoryKey = ""
    @Published private(set) var state: SettingsAuthState = .loading
    @Published private(set) var discoveryState: RepositoryDiscoveryState = .idle
    @Published private(set) var codeRootPath: String?
    @Published private(set) var discoveredRepositories: [DiscoveredRepository] = []
    @Published private(set) var skippedLocalRepositories: [SkippedLocalRepository] = []
    @Published private(set) var etagVerificationState: ETagVerificationState = .idle
    @Published private(set) var githubDebugEntries: [GitHubDebugEntry] = []
    @Published private(set) var repositoryAccessNotice: String?
    @Published private(set) var pollSchedulerSnapshot: PollSchedulerSnapshot = .idle

    private static let logger = Logger(subsystem: "app.runbar.Runbar", category: "authentication")
    private static let discoveryLogger = Logger(subsystem: "app.runbar.Runbar", category: "discovery")

    private let credentialStore: any CredentialStore
    private let authValidator: any AuthValidating
    private let repoDiscovery: RepoDiscovery?
    private let discoveryInitializationError: String?
    private let githubClient: GitHubClient?
    private let githubInitializationError: String?
    private let pollScheduler: PollScheduler?
    private var hasLoaded = false
    private var isObservingPollScheduler = false
    private var periodicRefreshTask: Task<Void, Never>?
    private var wakeObservationTask: Task<Void, Never>?

    init(
        credentialStore: any CredentialStore,
        authValidator: any AuthValidating,
        repoDiscovery: RepoDiscovery? = nil,
        discoveryInitializationError: String? = nil,
        githubClient: GitHubClient? = nil,
        githubInitializationError: String? = nil,
        pollScheduler: PollScheduler? = nil
    ) {
        self.credentialStore = credentialStore
        self.authValidator = authValidator
        self.repoDiscovery = repoDiscovery
        self.discoveryInitializationError = discoveryInitializationError
        self.githubClient = githubClient
        self.githubInitializationError = githubInitializationError
        self.pollScheduler = pollScheduler
    }

    deinit {
        periodicRefreshTask?.cancel()
        wakeObservationTask?.cancel()
    }

    var isBusy: Bool {
        state == .loading || state == .validating
    }

    var isRefreshingRepositories: Bool {
        discoveryState == .refreshing
    }

    var isRunningETagVerification: Bool {
        if case .running = etagVerificationState { return true }
        return false
    }

    var authenticatedLogin: String? {
        guard case let .authenticated(login) = state else { return nil }
        return login
    }

    var hasStoredCredential: Bool {
        switch state {
        case .authenticated:
            true
        case let .failed(_, hasStoredCredential):
            hasStoredCredential
        default:
            false
        }
    }

    var menuBarSystemImage: String {
        guard authenticatedLogin != nil else { return "circle.dashed" }
        return pollSchedulerSnapshot.isRateLimitDegraded
            ? "exclamationmark.triangle.fill"
            : "circle.fill"
    }

    var includedRepositoryCount: Int {
        discoveredRepositories.filter { !$0.isExcluded }.count
    }

    var verificationRepositories: [DiscoveredRepository] {
        discoveredRepositories.filter { !$0.isExcluded && $0.isAccessible }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await startPollSchedulerObservation()
        startWakeObservation()
        await loadStoredCredential()
        startPeriodicRefresh()
    }

    func loadStoredCredential() async {
        state = .loading

        let token: String
        do {
            guard let storedToken = try credentialStore.readToken() else {
                state = .signedOut
                await stopPollScheduler()
                await refreshDiscovery(token: nil)
                return
            }
            token = storedToken
        } catch {
            state = .failed(message: safeCredentialMessage(error), hasStoredCredential: false)
            await stopPollScheduler()
            await refreshDiscovery(token: nil)
            return
        }

        state = .validating
        do {
            let user = try await authValidator.validate(token: token)
            state = .authenticated(login: user.login)
            Self.logger.notice("Restored authenticated GitHub login \(user.login, privacy: .public) from a Keychain credential")
            await refreshDiscovery(token: token)
        } catch {
            state = .failed(message: safeAuthMessage(error), hasStoredCredential: true)
            Self.logger.error("Stored GitHub credential validation failed")
            await stopPollScheduler()
            await refreshDiscovery(token: nil)
        }
    }

    func saveEnteredToken() async {
        let candidate = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            state = .failed(
                message: CredentialStoreError.invalidToken.localizedDescription,
                hasStoredCredential: hasStoredCredential
            )
            return
        }

        let previouslyStored = credentialExists()
        state = .validating
        defer { tokenInput = "" }

        do {
            let user = try await authValidator.validate(token: candidate)
            try credentialStore.saveToken(candidate)
            state = .authenticated(login: user.login)
            Self.logger.notice("Validated and saved a Keychain credential for GitHub login \(user.login, privacy: .public)")
            await refreshDiscovery(token: candidate)
        } catch let error as AuthValidationError {
            state = .failed(message: error.userMessage, hasStoredCredential: previouslyStored)
            Self.logger.error("GitHub credential validation failed; the previous Keychain credential was preserved")
        } catch {
            state = .failed(message: safeCredentialMessage(error), hasStoredCredential: previouslyStored)
            Self.logger.error("Saving the validated GitHub credential to Keychain failed")
        }
    }

    func deleteCredential() {
        do {
            try credentialStore.deleteToken()
            tokenInput = ""
            state = .signedOut
            Self.logger.notice("Removed the GitHub credential from Keychain")
            Task {
                await stopPollScheduler()
                await refreshDiscovery(token: nil)
            }
        } catch {
            state = .failed(message: safeCredentialMessage(error), hasStoredCredential: true)
        }
    }

    func retryStoredCredential() async {
        await loadStoredCredential()
    }

    func chooseCodeRoot(_ url: URL) async {
        guard let repoDiscovery else {
            setDiscoveryInitializationFailure()
            return
        }
        discoveryState = .refreshing
        do {
            try await repoDiscovery.setCodeRoot(url)
            await refreshRepositories()
        } catch {
            discoveryState = .failed(message: safeDiscoveryMessage(error))
        }
    }

    func refreshRepositories() async {
        let token: String?
        do {
            token = try credentialStore.readToken()
        } catch {
            discoveryState = .failed(message: safeCredentialMessage(error))
            return
        }
        await refreshDiscovery(token: token)
    }

    func setExcluded(_ isExcluded: Bool, for repository: DiscoveredRepository) async {
        guard let repoDiscovery else {
            setDiscoveryInitializationFailure()
            return
        }
        do {
            try await repoDiscovery.setExcluded(isExcluded, repositoryKey: repository.id)
            if let index = discoveredRepositories.firstIndex(where: { $0.id == repository.id }) {
                discoveredRepositories[index].isExcluded = isExcluded
            }
            selectDefaultVerificationRepositoryIfNeeded()
            await configurePollScheduler()
        } catch {
            discoveryState = .failed(message: safeDiscoveryMessage(error))
        }
    }

    func runETagVerification() async {
        guard let githubClient else {
            let detail = githubInitializationError.map { ": \($0)" } ?? "."
            etagVerificationState = .failed(message: "Runbar could not open its GitHub cache\(detail)")
            return
        }
        guard let repository = verificationRepositories.first(where: { $0.id == verificationRepositoryKey }) else {
            etagVerificationState = .failed(message: "Choose an accessible repository first.")
            return
        }

        let token: String
        do {
            guard let storedToken = try credentialStore.readToken() else {
                etagVerificationState = .failed(message: "Save a GitHub credential before running the ETag check.")
                return
            }
            token = storedToken
        } catch {
            etagVerificationState = .failed(message: safeCredentialMessage(error))
            return
        }

        await githubClient.clearDebugEntries()
        githubDebugEntries = []
        repositoryAccessNotice = nil

        for index in 0..<11 {
            etagVerificationState = .running(completedRequests: index)
            do {
                _ = try await githubClient.get(
                    ActionsRunsProbe.self,
                    endpoint: .actionsRuns(repository: repository.identity),
                    token: token,
                    repositoryKey: repository.id
                )
            } catch let error as GitHubClientError {
                githubDebugEntries = await githubClient.debugEntries()
                handleGitHubClientError(error, repository: repository)
                return
            } catch {
                githubDebugEntries = await githubClient.debugEntries()
                etagVerificationState = .failed(message: GitHubClientError.transport.userMessage)
                return
            }
            githubDebugEntries = await githubClient.debugEntries()
            etagVerificationState = .running(completedRequests: index + 1)
        }

        let measured = Array(githubDebugEntries.suffix(10))
        let remaining = measured.compactMap(\.rateLimit.remaining)
        let all304 = measured.count == 10 && measured.allSatisfy { $0.statusCode == 304 }
        let allRemainingPresent = remaining.count == 10
        let nonDecreasing = zip(remaining, remaining.dropFirst()).allSatisfy { earlier, later in
            later >= earlier
        }
        if all304 && allRemainingPresent && nonDecreasing {
            etagVerificationState = .succeeded
        } else {
            etagVerificationState = .failed(
                message: "The last ten requests were not stable free 304s; inspect the debug rows below."
            )
        }
    }

    private func startPeriodicRefresh() {
        guard periodicRefreshTask == nil else { return }
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30 * 60))
                } catch {
                    return
                }
                guard let self else { return }
                await self.refreshRepositories()
            }
        }
    }

    private func startWakeObservation() {
        guard wakeObservationTask == nil, pollScheduler != nil else { return }
        wakeObservationTask = Task { @MainActor [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didWakeNotification
            )
            for await _ in notifications {
                guard !Task.isCancelled, let self, let scheduler = self.pollScheduler else { return }
                await scheduler.handleWake()
            }
        }
    }

    private func startPollSchedulerObservation() async {
        guard !isObservingPollScheduler, let pollScheduler else { return }
        isObservingPollScheduler = true
        await pollScheduler.setEventHandler { [weak self] snapshot in
            await self?.receivePollSchedulerSnapshot(snapshot)
        }
    }

    private func receivePollSchedulerSnapshot(_ snapshot: PollSchedulerSnapshot) {
        pollSchedulerSnapshot = snapshot
        if snapshot.hasAuthenticationFailure, hasStoredCredential {
            state = .failed(
                message: "GitHub rejected the saved credential while polling.",
                hasStoredCredential: true
            )
        }
    }

    private func configurePollScheduler() async {
        guard let pollScheduler else { return }
        guard authenticatedLogin != nil else {
            await stopPollScheduler()
            return
        }
        let repositories = verificationRepositories.map {
            PollRepository(key: $0.id, identity: $0.identity, pushedAt: $0.pushedAt)
        }
        guard !repositories.isEmpty else {
            await stopPollScheduler()
            return
        }

        let snapshot = await pollScheduler.snapshot()
        if snapshot.isRunning {
            await pollScheduler.updateRepositories(repositories)
        } else {
            await pollScheduler.start(repositories: repositories)
        }
    }

    private func stopPollScheduler() async {
        guard let pollScheduler else { return }
        let snapshot = await pollScheduler.snapshot()
        if snapshot.isRunning || snapshot.sessionStartedAt != nil {
            await pollScheduler.stop()
        }
        pollSchedulerSnapshot = await pollScheduler.snapshot()
    }

    private func refreshDiscovery(token: String?) async {
        guard let repoDiscovery else {
            setDiscoveryInitializationFailure()
            return
        }
        discoveryState = .refreshing
        do {
            let snapshot = try await repoDiscovery.refresh(token: token)
            codeRootPath = snapshot.codeRootPath
            discoveredRepositories = snapshot.repositories
            skippedLocalRepositories = snapshot.skippedLocalRepositories
            selectDefaultVerificationRepositoryIfNeeded()
            discoveryState = .loaded
            await configurePollScheduler()
            Self.discoveryLogger.notice(
                "Discovered \(snapshot.repositories.count, privacy: .public) repositories and excluded \(snapshot.skippedLocalRepositories.count, privacy: .public) local candidates"
            )
        } catch {
            discoveryState = .failed(message: safeDiscoveryMessage(error))
            Self.discoveryLogger.error("Repository discovery failed without logging paths, repository names, or credentials")
        }
    }

    private func selectDefaultVerificationRepositoryIfNeeded() {
        if !verificationRepositories.contains(where: { $0.id == verificationRepositoryKey }) {
            verificationRepositoryKey = verificationRepositories.first?.id ?? ""
        }
    }

    private func handleGitHubClientError(
        _ error: GitHubClientError,
        repository: DiscoveredRepository
    ) {
        switch error {
        case .authentication:
            state = .failed(message: error.userMessage, hasStoredCredential: true)
            etagVerificationState = .failed(message: error.userMessage)
        case let .accessDenied(repositoryKey, firstNotice):
            if let index = discoveredRepositories.firstIndex(where: { $0.id == repositoryKey }) {
                discoveredRepositories[index].isAccessible = false
            }
            if firstNotice {
                repositoryAccessNotice = "\(repository.identity.fullName) is inaccessible to the saved fine-grained token and will no longer be polled."
            }
            selectDefaultVerificationRepositoryIfNeeded()
            etagVerificationState = .failed(message: error.userMessage)
            Task { await configurePollScheduler() }
        default:
            etagVerificationState = .failed(message: error.userMessage)
        }
    }

    private func setDiscoveryInitializationFailure() {
        let detail = discoveryInitializationError.map { ": \($0)" } ?? "."
        discoveryState = .failed(message: "Runbar could not open its local SQLite store\(detail)")
    }

    private func credentialExists() -> Bool {
        do { return try credentialStore.readToken() != nil }
        catch { return hasStoredCredential }
    }

    private func safeAuthMessage(_ error: Error) -> String {
        (error as? AuthValidationError)?.userMessage ?? AuthValidationError.transport.userMessage
    }

    private func safeCredentialMessage(_ error: Error) -> String {
        (error as? CredentialStoreError)?.localizedDescription
            ?? "The macOS Keychain operation failed."
    }

    private func safeDiscoveryMessage(_ error: Error) -> String {
        (error as? RepoDiscoveryError)?.userMessage
            ?? "Repository discovery failed."
    }
}

private struct ActionsRunsProbe: Decodable, Sendable {
    let totalCount: Int

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
    }
}
