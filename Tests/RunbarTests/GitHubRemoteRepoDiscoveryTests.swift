import Foundation
import XCTest
@testable import Runbar

final class GitHubRemoteRepoDiscoveryTests: XCTestCase {
    func testRequestShapeTopThirtyAndExplicit304Reuse() async throws {
        let payload: [[String: Any]] = (0..<35).map { index in
            [
                "full_name": "owner/repo\(String(format: "%02d", index))",
                "pushed_at": String(format: "2026-01-01T00:00:%02dZ", index)
            ]
        }
        let transport = RemoteDiscoveryTransportStub(
            steps: [
                .init(
                    statusCode: 200,
                    body: try JSONSerialization.data(withJSONObject: payload),
                    headers: ["ETag": #""repos-v1""#, "x-ratelimit-remaining": "4999"]
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
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[0].url,
            "https://api.github.com/user/repos?direction=desc&per_page=100&sort=pushed"
        )
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].accept, "application/vnd.github+json")
        XCTAssertEqual(requests[0].apiVersion, "2022-11-28")
        XCTAssertEqual(requests[0].authorization, "Bearer m2-remote-request-marker")
        XCTAssertNil(requests[0].ifNoneMatch)
        XCTAssertEqual(requests[1].ifNoneMatch, #""repos-v1""#)
        XCTAssertEqual(
            requests[1].cachePolicy,
            URLRequest.CachePolicy.reloadIgnoringLocalAndRemoteCacheData.rawValue
        )
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
