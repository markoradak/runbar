import Foundation
import Security

struct KeychainGitHubAppCredentialStore: GitHubAppCredentialStoring, @unchecked Sendable {
    static let production = KeychainGitHubAppCredentialStore(
        service: "app.runbar.Runbar.github",
        account: "github-app-user-credential"
    )

    let service: String
    let account: String

    func readCredential() throws -> GitHubAppCredential? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw CredentialStoreError.invalidStoredData }
            do { return try JSONDecoder().decode(GitHubAppCredential.self, from: data) }
            catch { throw CredentialStoreError.invalidStoredData }
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychainFailure(status)
        }
    }

    func saveCredential(_ credential: GitHubAppCredential) throws {
        guard !credential.accessToken.isEmpty else { throw CredentialStoreError.invalidToken }
        let data = try JSONEncoder().encode(credential)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw CredentialStoreError.keychainFailure(addStatus)
        }
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(updateStatus)
        }
    }

    func deleteCredential() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

actor GitHubAppSession: GitHubAppSessionManaging {
    private let store: any GitHubAppCredentialStoring
    private let authenticator: any GitHubAppAuthenticating
    private let now: @Sendable () -> Date

    init(
        store: any GitHubAppCredentialStoring,
        authenticator: any GitHubAppAuthenticating,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.authenticator = authenticator
        self.now = now
    }

    func readCredential() async throws -> String? {
        guard let credential = try store.readCredential() else { return nil }
        guard let expiresAt = credential.accessTokenExpiresAt,
              expiresAt <= now().addingTimeInterval(60)
        else { return credential.accessToken }
        guard let refreshToken = credential.refreshToken,
              credential.refreshTokenExpiresAt.map({ $0 > now() }) != false
        else {
            try store.deleteCredential()
            return nil
        }
        let response = try await authenticator.refreshCredential(refreshToken: refreshToken)
        let refreshed = GitHubAppCredential(
            accessToken: response.accessToken,
            accessTokenExpiresAt: response.accessTokenExpiresAt,
            refreshToken: response.refreshToken ?? credential.refreshToken,
            refreshTokenExpiresAt: response.refreshTokenExpiresAt ?? credential.refreshTokenExpiresAt
        )
        try store.saveCredential(refreshed)
        return refreshed.accessToken
    }

    func saveCredential(_ credential: GitHubAppCredential) async throws {
        try store.saveCredential(credential)
    }

    func deleteCredential() async throws {
        try store.deleteCredential()
    }
}
