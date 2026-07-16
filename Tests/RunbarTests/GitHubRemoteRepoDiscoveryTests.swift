import Foundation
import XCTest
@testable import Runbar

final class GitHubRemoteRepoDiscoveryTests: XCTestCase {
    func testRequestShapeTopThirtyAndExplicit304Reuse() async throws {
        let repositories: [[String: Any]] = (0..<35).map { index in
            [
                "full_name": "owner/repo\(String(format: "%02d", index))",
                "pushed_at": String(format: "2026-01-01T00:00:%02dZ", index)
            ]
        }
        let installationsPayload: [String: Any] = [
            "total_count": 1,
            "installations": [["id": 987_654]]
        ]
        let repositoriesPayload: [String: Any] = [
            "total_count": repositories.count,
            "repositories": repositories
        ]
        let transport = RemoteDiscoveryTransportStub(
            steps: [
                .init(
                    statusCode: 200,
                    body: try JSONSerialization.data(withJSONObject: installationsPayload),
                    headers: ["ETag": #""installations-v1""#, "x-ratelimit-remaining": "4999"]
                ),
                .init(
                    statusCode: 200,
                    body: try JSONSerialization.data(withJSONObject: repositoriesPayload),
                    headers: ["ETag": #""repos-v1""#, "x-ratelimit-remaining": "4999"]
                ),
                .init(
                    statusCode: 304,
                    body: Data(),
                    headers: ["x-ratelimit-remaining": "4999"]
                ),
                .init(
                    statusCode: 304,
                    body: Data(),
                    headers: ["x-ratelimit-remaining": "4999"]
                )
            ]
        )
        let client = GitHubClient(
            store: RemoteDiscoveryStoreStub(),
            transport: transport
        )
        let discovery = GitHubRemoteRepoDiscovery(client: client)

        let fresh = try await discovery.discover(token: "m2-remote-request-marker")
        let revalidated = try await discovery.discover(token: "m2-remote-request-marker")
        let requests = await transport.requests()

        XCTAssertEqual(fresh.count, 30)
        XCTAssertEqual(fresh.first?.identity.fullName, "owner/repo34")
        XCTAssertEqual(fresh.last?.identity.fullName, "owner/repo05")
        XCTAssertEqual(revalidated, fresh)
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(
            requests[0].url,
            "https://api.github.com/user/installations?page=1&per_page=100"
        )
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].accept, "application/vnd.github+json")
        XCTAssertEqual(requests[0].apiVersion, "2022-11-28")
        XCTAssertEqual(requests[0].authorization, "Bearer m2-remote-request-marker")
        XCTAssertNil(requests[0].ifNoneMatch)
        XCTAssertEqual(
            requests[1].url,
            "https://api.github.com/user/installations/987654/repositories?page=1&per_page=100"
        )
        XCTAssertNil(requests[1].ifNoneMatch)
        XCTAssertEqual(requests[2].ifNoneMatch, #""installations-v1""#)
        XCTAssertEqual(requests[3].ifNoneMatch, #""repos-v1""#)
        XCTAssertEqual(
            requests[3].cachePolicy,
            URLRequest.CachePolicy.reloadIgnoringLocalAndRemoteCacheData.rawValue
        )
    }

    func testAllRepositoriesInstallationPaginatesBeforeSelectingTopThirty() async throws {
        let repositories: [[String: Any]] = (0..<101).map { index in
            [
                "full_name": "large-org/repo\(String(format: "%03d", index))",
                "pushed_at": String(format: "2026-01-01T00:%02d:%02dZ", index / 60, index % 60)
            ]
        }
        let transport = RemoteDiscoveryTransportStub(
            steps: [
                .init(
                    statusCode: 200,
                    body: try JSONSerialization.data(withJSONObject: [
                        "total_count": 1,
                        "installations": [["id": 42]]
                    ]),
                    headers: ["ETag": #""installations""#]
                ),
                .init(
                    statusCode: 200,
                    body: try JSONSerialization.data(withJSONObject: [
                        "total_count": 101,
                        "repositories": Array(repositories.prefix(100))
                    ]),
                    headers: ["ETag": #""repos-page-1""#]
                ),
                .init(
                    statusCode: 200,
                    body: try JSONSerialization.data(withJSONObject: [
                        "total_count": 101,
                        "repositories": Array(repositories.suffix(1))
                    ]),
                    headers: ["ETag": #""repos-page-2""#]
                )
            ]
        )
        let discovery = GitHubRemoteRepoDiscovery(
            client: GitHubClient(store: RemoteDiscoveryStoreStub(), transport: transport)
        )

        let result = try await discovery.discover(token: "pagination-marker")
        let requests = await transport.requests()

        XCTAssertEqual(result.count, 30)
        XCTAssertEqual(result.first?.identity.fullName, "large-org/repo100")
        XCTAssertEqual(result.last?.identity.fullName, "large-org/repo071")
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests[2].url,
            "https://api.github.com/user/installations/42/repositories?page=2&per_page=100"
        )
        XCTAssertEqual(requests[2].authorization, "Bearer pagination-marker")
    }
}

private actor RemoteDiscoveryTransportStub: GitHubTransport {
    struct Step: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]
    }

    struct CapturedRequest: Sendable {
        let url: String
        let method: String?
        let accept: String?
        let apiVersion: String?
        let authorization: String?
        let ifNoneMatch: String?
        let cachePolicy: UInt
    }

    private var steps: [Step]
    private var captured: [CapturedRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(
            CapturedRequest(
                url: request.url?.absoluteString ?? "",
                method: request.httpMethod,
                accept: request.value(forHTTPHeaderField: "Accept"),
                apiVersion: request.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match"),
                cachePolicy: request.cachePolicy.rawValue
            )
        )
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        return (
            step.body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: step.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: step.headers
            )!
        )
    }

    func requests() -> [CapturedRequest] { captured }
}

private actor RemoteDiscoveryStoreStub: GitHubClientStoring {
    private var cached: [String: GitHubCachedResponse] = [:]

    func cachedResponse(for canonicalURL: String) async throws -> GitHubCachedResponse? {
        cached[canonicalURL]
    }

    func saveCachedResponse(_ response: GitHubCachedResponse, for canonicalURL: String) async throws {
        cached[canonicalURL] = response
    }

    func isRepositoryAccessible(_ repositoryKey: String) async throws -> Bool { true }
    func markRepositoryInaccessible(_ repositoryKey: String) async throws -> Bool { true }
    func setRepositoryAccessible(_ isAccessible: Bool, repositoryKey: String) async throws {}
    func appendDebugEntry(_ entry: GitHubDebugEntry) async throws {}
    func clearDebugEntries() async throws {}
}
