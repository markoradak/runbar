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

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tokenInput = ""
    @Published private(set) var state: SettingsAuthState = .loading
    @Published private(set) var discoveryState: RepositoryDiscoveryState = .idle
    @Published private(set) var codeRootPath: String?
    @Published private(set) var discoveredRepositories: [DiscoveredRepository] = []
    @Published private(set) var skippedLocalRepositories: [SkippedLocalRepository] = []

    private static let logger = Logger(subsystem: "app.runbar.Runbar", category: "authentication")
    private static let discoveryLogger = Logger(subsystem: "app.runbar.Runbar", category: "discovery")

    private let credentialStore: any CredentialStore
    private let authValidator: any AuthValidating
    private let repoDiscovery: RepoDiscovery?
    private let discoveryInitializationError: String?
    private var hasLoaded = false
    private var periodicRefreshTask: Task<Void, Never>?

    init(
        credentialStore: any CredentialStore,
        authValidator: any AuthValidating,
        repoDiscovery: RepoDiscovery? = nil,
        discoveryInitializationError: String? = nil
    ) {
        self.credentialStore = credentialStore
        self.authValidator = authValidator
        self.repoDiscovery = repoDiscovery
        self.discoveryInitializationError = discoveryInitializationError
    }

    var isBusy: Bool {
        state == .loading || state == .validating
    }

    var isRefreshingRepositories: Bool {
        discoveryState == .refreshing
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
        authenticatedLogin == nil ? "circle.dashed" : "circle.fill"
    }

    var includedRepositoryCount: Int {
        discoveredRepositories.filter { !$0.isExcluded }.count
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await loadStoredCredential()
        startPeriodicRefresh()
    }

    func loadStoredCredential() async {
        state = .loading

        let token: String
        do {
            guard let storedToken = try credentialStore.readToken() else {
                state = .signedOut
                await refreshDiscovery(token: nil)
                return
            }
            token = storedToken
        } catch {
            state = .failed(message: safeCredentialMessage(error), hasStoredCredential: false)
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
            Task { await refreshDiscovery(token: nil) }
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
        } catch {
            discoveryState = .failed(message: safeDiscoveryMessage(error))
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
            discoveryState = .loaded
            Self.discoveryLogger.notice(
                "Discovered \(snapshot.repositories.count, privacy: .public) repositories and excluded \(snapshot.skippedLocalRepositories.count, privacy: .public) local candidates"
            )
        } catch {
            discoveryState = .failed(message: safeDiscoveryMessage(error))
            Self.discoveryLogger.error("Repository discovery failed without logging paths, repository names, or credentials")
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
