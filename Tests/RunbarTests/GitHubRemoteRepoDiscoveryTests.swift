import Foundation
import XCTest
@testable import Runbar

final class GitHubRemoteRepoDiscoveryTests: XCTestCase {
    func testRequestShapeAndTopThirtyByPushedAt() async throws {
        let payload: [[String: Any]] = (0..<35).map { index in
            [
                "full_name": "owner/repo\(String(format: "%02d", index))",
                "pushed_at": String(format: "2026-01-01T00:00:%02dZ", index)
            ]
        }
        let transport = RemoteDiscoveryTransportStub(
            statusCode: 200,
            body: try JSONSerialization.data(withJSONObject: payload)
        )
        let discovery = GitHubRemoteRepoDiscovery(transport: transport)

        let repositories = try await discovery.discover(token: "m1-remote-request-marker")
        let requestURL = await transport.url()
        let method = await transport.method()
        let accept = await transport.header(named: "Accept")
        let apiVersion = await transport.header(named: "X-GitHub-Api-Version")
        let hasAuthorization = await transport.usedExpectedAuthorization(token: "m1-remote-request-marker")
        let cachePolicy = await transport.cachePolicy()

        XCTAssertEqual(repositories.count, 30)
        XCTAssertEqual(repositories.first?.identity.fullName, "owner/repo34")
        XCTAssertEqual(repositories.last?.identity.fullName, "owner/repo05")
        XCTAssertEqual(
            requestURL?.absoluteString,
            "https://api.github.com/user/repos?sort=pushed&direction=desc&per_page=100"
        )
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(accept, "application/vnd.github+json")
        XCTAssertEqual(apiVersion, "2022-11-28")
        XCTAssertTrue(hasAuthorization)
        XCTAssertEqual(cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }
}

private actor RemoteDiscoveryTransportStub: AuthTransport {
    let statusCode: Int
    let body: Data
    private var request: URLRequest?

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (
            body,
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }

    func url() -> URL? { request?.url }
    func method() -> String? { request?.httpMethod }
    func header(named name: String) -> String? { request?.value(forHTTPHeaderField: name) }
    func cachePolicy() -> URLRequest.CachePolicy? { request?.cachePolicy }
    func usedExpectedAuthorization(token: String) -> Bool {
        request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
    }
}
