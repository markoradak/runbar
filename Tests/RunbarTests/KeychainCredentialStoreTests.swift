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

    private func makeStore() -> KeychainCredentialStore {
        KeychainCredentialStore(
            service: "app.runbar.RunbarTests.\(UUID().uuidString)",
            account: "integration-test-token"
        )
    }
}
