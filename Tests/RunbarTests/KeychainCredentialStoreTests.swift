import XCTest
@testable import Runbar

final class KeychainCredentialStoreTests: XCTestCase {
    func testAddReadUpdateAndDeleteCredential() throws {
        let store = makeStore()
        try? store.deleteToken()
        defer { try? store.deleteToken() }

        XCTAssertNil(try store.readToken())

        try store.saveToken("m0-keychain-integration-marker-one")
        XCTAssertTrue(try store.readToken() == "m0-keychain-integration-marker-one")

        try store.saveToken("m0-keychain-integration-marker-two")
        XCTAssertTrue(try store.readToken() == "m0-keychain-integration-marker-two")

        try store.deleteToken()
        XCTAssertNil(try store.readToken())
    }

    func testEmptyCredentialIsRejected() {
        let store = makeStore()
        XCTAssertThrowsError(try store.saveToken("")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .invalidToken)
        }
    }

    func testGitHubAppCredentialRoundTripsOnlyThroughKeychain() throws {
        let store = KeychainGitHubAppCredentialStore(
            service: "app.runbar.RunbarTests.\(UUID().uuidString)",
            account: "github-app-integration-test"
        )
        let credential = GitHubAppCredential(
            accessToken: "github-app-access-marker",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            refreshToken: "github-app-refresh-marker",
            refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_810_000_000)
        )
        try? store.deleteCredential()
        defer { try? store.deleteCredential() }

        XCTAssertNil(try store.readCredential())
        try store.saveCredential(credential)
        XCTAssertEqual(try store.readCredential(), credential)
        try store.deleteCredential()
        XCTAssertNil(try store.readCredential())
    }

    private func makeStore() -> KeychainCredentialStore {
        KeychainCredentialStore(
            service: "app.runbar.RunbarTests.\(UUID().uuidString)",
            account: "integration-test-token"
        )
    }
}
