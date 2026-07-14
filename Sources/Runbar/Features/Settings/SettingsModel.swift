import Foundation
import os

enum SettingsAuthState: Equatable {
    case loading
    case signedOut
    case validating
    case authenticated(login: String)
    case failed(message: String, hasStoredCredential: Bool)
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tokenInput = ""
    @Published private(set) var state: SettingsAuthState = .loading

    private static let logger = Logger(subsystem: "app.runbar.Runbar", category: "authentication")

    private let credentialStore: any CredentialStore
    private let authValidator: any AuthValidating
    private var hasLoaded = false

    init(credentialStore: any CredentialStore, authValidator: any AuthValidating) {
        self.credentialStore = credentialStore
        self.authValidator = authValidator
    }

    var isBusy: Bool {
        state == .loading || state == .validating
    }

    var authenticatedLogin: String? {
        guard case let .authenticated(login) = state else {
            return nil
        }
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

    func loadIfNeeded() async {
        guard !hasLoaded else {
            return
        }
        hasLoaded = true
        await loadStoredCredential()
    }

    func loadStoredCredential() async {
        state = .loading

        let token: String
        do {
            guard let storedToken = try credentialStore.readToken() else {
                state = .signedOut
                return
            }
            token = storedToken
        } catch {
            state = .failed(message: safeCredentialMessage(error), hasStoredCredential: false)
            return
        }

        state = .validating
        do {
            let user = try await authValidator.validate(token: token)
            state = .authenticated(login: user.login)
            Self.logger.notice("Restored authenticated GitHub login \(user.login, privacy: .public) from a Keychain credential")
        } catch {
            state = .failed(message: safeAuthMessage(error), hasStoredCredential: true)
            Self.logger.error("Stored GitHub credential validation failed")
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
        } catch {
            state = .failed(message: safeCredentialMessage(error), hasStoredCredential: true)
        }
    }

    func retryStoredCredential() async {
        await loadStoredCredential()
    }

    private func credentialExists() -> Bool {
        do {
            return try credentialStore.readToken() != nil
        } catch {
            return hasStoredCredential
        }
    }

    private func safeAuthMessage(_ error: Error) -> String {
        (error as? AuthValidationError)?.userMessage ?? AuthValidationError.transport.userMessage
    }

    private func safeCredentialMessage(_ error: Error) -> String {
        (error as? CredentialStoreError)?.localizedDescription
            ?? "The macOS Keychain operation failed."
    }
}
