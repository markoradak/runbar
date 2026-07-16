import Foundation
import XCTest
@testable import Runbar

final class GitHubAppAuthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRunbarInstallationLinksUseConfiguredAppSlug() {
        XCTAssertEqual(GitHubAppConfiguration.slug, "runbar")
        XCTAssertEqual(
            GitHubAppConfiguration.installationURL.absoluteString,
            "https://github.com/apps/runbar/installations/new"
        )
        XCTAssertEqual(
            GitHubAppConfiguration.managementURL.absoluteString,
            "https://github.com/settings/installations"
        )
    }

    func testDeviceAuthorizationUsesClientIDAndDecodesGitHubResponse() async throws {
        let fixedNow = now
        let transport = AppAuthTransportStub(
            responses: [
                .success(#"{"device_code":"device-secret","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
            ]
        )
        let client = GitHubAppAuthClient(clientID: "client-marker", transport: transport, now: { fixedNow })

        let authorization = try await client.requestDeviceAuthorization()
        let capturedRequests = await transport.requests()
        let request = try XCTUnwrap(capturedRequests.first)

        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.verificationURL.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(authorization.expiresAt, now.addingTimeInterval(900))
        XCTAssertEqual(authorization.pollingInterval, 5)
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "client_id=client-marker")
    }

    func testPendingDeviceAuthorizationIsExplicit() async {
        let transport = AppAuthTransportStub(responses: [.success(#"{"error":"authorization_pending"}"#)])
        let client = GitHubAppAuthClient(clientID: "client-marker", transport: transport)

        do {
            _ = try await client.pollForCredential(deviceCode: "device-marker")
            XCTFail("Expected authorization to remain pending")
        } catch {
            XCTAssertEqual(error as? GitHubAppAuthError, .authorizationPending)
        }
    }

    func testDeviceCredentialAndRefreshCredentialCarryExpirations() async throws {
        let fixedNow = now
        let transport = AppAuthTransportStub(
            responses: [
                .success(#"{"access_token":"access-one","expires_in":28800,"refresh_token":"refresh-one","refresh_token_expires_in":15811200}"#),
                .success(#"{"access_token":"access-two","expires_in":28800,"refresh_token":"refresh-two","refresh_token_expires_in":15811200}"#)
            ]
        )
        let client = GitHubAppAuthClient(clientID: "client-marker", transport: transport, now: { fixedNow })

        let initial = try await client.pollForCredential(deviceCode: "device-marker")
        let refreshed = try await client.refreshCredential(refreshToken: "refresh-one")
        let requests = await transport.requests()

        XCTAssertEqual(initial.accessToken, "access-one")
        XCTAssertEqual(initial.accessTokenExpiresAt, now.addingTimeInterval(28_800))
        XCTAssertEqual(initial.refreshTokenExpiresAt, now.addingTimeInterval(15_811_200))
        XCTAssertEqual(refreshed.accessToken, "access-two")
        XCTAssertEqual(refreshed.refreshToken, "refresh-two")
        XCTAssertTrue(String(data: requests[0].httpBody ?? Data(), encoding: .utf8)?.contains("device_code=device-marker") == true)
        XCTAssertTrue(String(data: requests[1].httpBody ?? Data(), encoding: .utf8)?.contains("refresh_token=refresh-one") == true)
    }

    func testExpiredAccessTokenRefreshesAndPersistsBeforeUse() async throws {
        let fixedNow = now
        let expired = GitHubAppCredential(
            accessToken: "expired-access",
            accessTokenExpiresAt: now.addingTimeInterval(-1),
            refreshToken: "refresh-marker",
            refreshTokenExpiresAt: now.addingTimeInterval(3_600)
        )
        let refreshed = GitHubAppCredential(
            accessToken: "fresh-access",
            accessTokenExpiresAt: now.addingTimeInterval(28_800),
            refreshToken: "fresh-refresh",
            refreshTokenExpiresAt: now.addingTimeInterval(15_811_200)
        )
        let store = MemoryGitHubAppCredentialStore(credential: expired)
        let authenticator = AppAuthenticatorStub(refreshedCredential: refreshed)
        let session = GitHubAppSession(store: store, authenticator: authenticator, now: { fixedNow })

        let accessToken = try await session.readCredential()
        let receivedRefreshTokens = await authenticator.receivedRefreshTokens()

        XCTAssertEqual(accessToken, "fresh-access")
        XCTAssertEqual(store.credential(), refreshed)
        XCTAssertEqual(receivedRefreshTokens, ["refresh-marker"])
    }
}

private actor AppAuthTransportStub: AuthTransport {
    enum Response: Sendable {
        case success(String)
    }

    private var responses: [Response]
    private var captured: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let response = responses.removeFirst()
        let body: Data
        switch response {
        case let .success(json): body = Data(json.utf8)
        }
        return (
            body,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }

    func requests() -> [URLRequest] { captured }
}

private final class MemoryGitHubAppCredentialStore: GitHubAppCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCredential: GitHubAppCredential?

    init(credential: GitHubAppCredential?) {
        storedCredential = credential
    }

    func readCredential() throws -> GitHubAppCredential? {
        lock.withLock { storedCredential }
    }

    func saveCredential(_ credential: GitHubAppCredential) throws {
        lock.withLock { storedCredential = credential }
    }

    func deleteCredential() throws {
        lock.withLock { storedCredential = nil }
    }

    func credential() -> GitHubAppCredential? {
        lock.withLock { storedCredential }
    }
}

private actor AppAuthenticatorStub: GitHubAppAuthenticating {
    private let refreshedCredential: GitHubAppCredential
    private var refreshTokens: [String] = []

    init(refreshedCredential: GitHubAppCredential) {
        self.refreshedCredential = refreshedCredential
    }

    func requestDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
        throw GitHubAppAuthError.invalidResponse
    }

    func pollForCredential(deviceCode: String) async throws -> GitHubAppCredential {
        throw GitHubAppAuthError.invalidResponse
    }

    func refreshCredential(refreshToken: String) async throws -> GitHubAppCredential {
        refreshTokens.append(refreshToken)
        return refreshedCredential
    }

    func receivedRefreshTokens() -> [String] { refreshTokens }
}
