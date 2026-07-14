import XCTest
@testable import Runbar

@MainActor
final class SettingsModelTests: XCTestCase {
    func testLaunchWithoutCredentialIsSignedOut() async {
        let store = MemoryCredentialStore()
        let model = SettingsModel(credentialStore: store, authValidator: StubAuthValidator.success(login: "unused"))

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .signedOut)
    }

    func testLaunchValidatesStoredCredentialAndDisplaysLogin() async {
        let store = MemoryCredentialStore(token: "stored-launch-marker")
        let validator = StubAuthValidator.success(login: "octocat")
        let model = SettingsModel(credentialStore: store, authValidator: validator)

        await model.loadIfNeeded()
        let receivedStoredToken = await validator.received(token: "stored-launch-marker")

        XCTAssertEqual(model.state, .authenticated(login: "octocat"))
        XCTAssertEqual(model.authenticatedLogin, "octocat")
        XCTAssertTrue(receivedStoredToken)
    }

    func testValidTokenIsSavedOnlyAfterValidationAndInputIsCleared() async {
        let store = MemoryCredentialStore()
        let validator = StubAuthValidator.success(login: "hubot")
        let model = SettingsModel(credentialStore: store, authValidator: validator)
        model.tokenInput = "candidate-save-marker"

        await model.saveEnteredToken()

        XCTAssertEqual(model.state, .authenticated(login: "hubot"))
        XCTAssertTrue(store.token == "candidate-save-marker")
        XCTAssertEqual(model.tokenInput, "")
    }

    func testFailedReplacementPreservesKnownGoodCredential() async {
        let store = MemoryCredentialStore(token: "known-good-marker")
        let model = SettingsModel(credentialStore: store, authValidator: StubAuthValidator.failure(.invalidToken))
        model.tokenInput = "bad-replacement-marker"

        await model.saveEnteredToken()

        XCTAssertTrue(store.token == "known-good-marker")
        XCTAssertEqual(
            model.state,
            .failed(message: AuthValidationError.invalidToken.userMessage, hasStoredCredential: true)
        )
        XCTAssertEqual(model.tokenInput, "")
    }

    func testDeleteRemovesCredentialAndSignsOut() {
        let store = MemoryCredentialStore(token: "delete-marker")
        let model = SettingsModel(credentialStore: store, authValidator: StubAuthValidator.success(login: "unused"))

        model.deleteCredential()

        XCTAssertNil(store.token)
        XCTAssertEqual(model.state, .signedOut)
    }
}

private final class MemoryCredentialStore: CredentialStore {
    var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func readToken() throws -> String? {
        token
    }

    func saveToken(_ token: String) throws {
        self.token = token
    }

    func deleteToken() throws {
        token = nil
    }
}

private actor StubAuthValidator: AuthValidating {
    private let result: Result<AuthenticatedUser, AuthValidationError>
    private var receivedTokens: [String] = []

    init(result: Result<AuthenticatedUser, AuthValidationError>) {
        self.result = result
    }

    static func success(login: String) -> StubAuthValidator {
        StubAuthValidator(result: .success(AuthenticatedUser(login: login)))
    }

    static func failure(_ error: AuthValidationError) -> StubAuthValidator {
        StubAuthValidator(result: .failure(error))
    }

    func validate(token: String) async throws -> AuthenticatedUser {
        receivedTokens.append(token)
        return try result.get()
    }

    func received(token: String) -> Bool {
        receivedTokens.contains(token)
    }
}
