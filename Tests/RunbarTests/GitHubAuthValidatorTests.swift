import XCTest
@testable import Runbar

final class GitHubAuthValidatorTests: XCTestCase {
    func testSuccessfulValidationBuildsExpectedReadOnlyUserRequest() async throws {
        let transport = AuthTransportStub(statusCode: 200, body: #"{"login":"octocat"}"#.data(using: .utf8)!)
        let validator = GitHubAuthValidator(transport: transport)

        let user = try await validator.validate(token: "m0-auth-request-marker")
        let usedExpectedAuthorization = await transport.usedExpectedAuthorization(token: "m0-auth-request-marker")
        let acceptHeader = await transport.header(named: "Accept")
        let apiVersionHeader = await transport.header(named: "X-GitHub-Api-Version")
        let method = await transport.method()
        let url = await transport.url()
        let cachePolicy = await transport.cachePolicy()

        XCTAssertEqual(user, AuthenticatedUser(login: "octocat"))
        XCTAssertTrue(usedExpectedAuthorization)
        XCTAssertEqual(acceptHeader, "application/vnd.github+json")
        XCTAssertEqual(apiVersionHeader, "2022-11-28")
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testUnauthorizedResponseMapsToInvalidToken() async {
        let validator = GitHubAuthValidator(transport: AuthTransportStub(statusCode: 401))
        await assertValidationError(.invalidToken) {
            try await validator.validate(token: "invalid-marker")
        }
    }

    func testForbiddenResponseExplainsPermissions() async {
        let validator = GitHubAuthValidator(transport: AuthTransportStub(statusCode: 403))
        await assertValidationError(.insufficientPermissions) {
            try await validator.validate(token: "forbidden-marker")
        }
    }

    func testMalformedSuccessPayloadIsRejected() async {
        let transport = AuthTransportStub(statusCode: 200, body: Data("{}".utf8))
        let validator = GitHubAuthValidator(transport: transport)
        await assertValidationError(.invalidPayload) {
            try await validator.validate(token: "payload-marker")
        }
    }

    func testTransportFailureMapsToSafeError() async {
        let validator = GitHubAuthValidator(transport: AuthTransportStub(throwsTransportError: true))
        await assertValidationError(.transport) {
            try await validator.validate(token: "transport-marker")
        }
    }

    private func assertValidationError(
        _ expected: AuthValidationError,
        operation: () async throws -> AuthenticatedUser
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected validation to fail")
        } catch {
            XCTAssertEqual(error as? AuthValidationError, expected)
        }
    }
}

private actor AuthTransportStub: AuthTransport {
    private let statusCode: Int
    private let body: Data
    private let throwsTransportError: Bool
    private var request: URLRequest?

    init(statusCode: Int = 200, body: Data = Data(), throwsTransportError: Bool = false) {
        self.statusCode = statusCode
        self.body = body
        self.throwsTransportError = throwsTransportError
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        if throwsTransportError {
            throw URLError(.notConnectedToInternet)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }

    func usedExpectedAuthorization(token: String) -> Bool {
        request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
    }

    func header(named name: String) -> String? {
        request?.value(forHTTPHeaderField: name)
    }

    func method() -> String? {
        request?.httpMethod
    }

    func url() -> URL? {
        request?.url
    }

    func cachePolicy() -> URLRequest.CachePolicy? {
        request?.cachePolicy
    }
}
