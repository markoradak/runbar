import Foundation

struct ProviderCredentialStore: @unchecked Sendable {
    static let production = ProviderCredentialStore(
        stores: [
            .vercel: KeychainCredentialStore(
                service: "app.runbar.Runbar.vercel",
                account: "read-only-access-token"
            ),
            .cloudflarePages: KeychainCredentialStore(
                service: "app.runbar.Runbar.cloudflare-pages",
                account: "pages-read-api-token"
            )
        ]
    )

    private let stores: [ExecutionProvider: KeychainCredentialStore]

    init(stores: [ExecutionProvider: KeychainCredentialStore]) {
        self.stores = stores
    }

    func readToken(for provider: ExecutionProvider) throws -> String? {
        try store(for: provider).readToken()
    }

    func saveToken(_ token: String, for provider: ExecutionProvider) throws {
        try store(for: provider).saveToken(token)
    }

    func deleteToken(for provider: ExecutionProvider) throws {
        try store(for: provider).deleteToken()
    }

    private func store(for provider: ExecutionProvider) throws -> KeychainCredentialStore {
        guard let store = stores[provider] else { throw CredentialStoreError.invalidStoredData }
        return store
    }
}
