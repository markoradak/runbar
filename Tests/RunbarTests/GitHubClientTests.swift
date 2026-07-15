import Foundation
import XCTest
@testable import Runbar

final class GitHubClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.github.test")!
    private let endpoint = GitHubEndpoint(
        pathSegments: ["repos", "Owner", "Private Repo", "actions", "runs"],
        queryItems: [.init(name: "per_page", value: "1")]
    )
    private let payload = Data(#"{"value":42}"#.utf8)

    func testCanonicalURLSortsQueryValuesAndSanitizesRepositoryIdentity() throws {
        let endpoint = GitHubEndpoint(
            pathSegments: ["repos", "Owner", "Private Repo", "actions", "runs"],
            queryItems: [
                .init(name: "z", value: "2"),
                .init(name: "a", value: "2"),
                .init(name: "a", value: "1"),
                .init(name: "token", value: "secret")
            ]
        )

        let url = try GitHubURLCanonicalizer.canonicalURL(baseURL: baseURL, endpoint: endpoint)

        XCTAssertEqual(
            url.absoluteString,
            "https://api.github.test/repos/Owner/Private%20Repo/actions/runs?a=1&a=2&token=secret&z=2"
        )
        XCTAssertEqual(
            GitHubURLCanonicalizer.sanitizedURL(url),
            "https://api.github.test/repos/%3Cowner%3E/%3Crepo%3E/actions/runs?a=1&a=2&token=%3Credacted%3E&z=2"
        )
    }

    func test200Then304UsesExplicitHeadersAndCachedBody() async throws {
        let store = MemoryGitHubStore()
        let transport = ScriptedGitHubTransport(steps: [
            .response(
                status: 200,
                headers: rateHeaders(etag: #""v1""#, remaining: 4_999),
                body: payload
            ),
            .response(
                status: 304,
                headers: rateHeaders(remaining: 4_999),
                body: Data()
            )
        ])
        let client = GitHubClient(store: store, transport: transport, baseURL: baseURL)

        let fresh = try await client.get(TestPayload.self, endpoint: endpoint, token: "top-secret")
        let cached = try await client.get(TestPayload.self, endpoint: endpoint, token: "top-secret")

        XCTAssertEqual(fresh.value.value, 42)
        XCTAssertEqual(fresh.statusCode, 200)
        XCTAssertEqual(fresh.cacheOutcome, .stored200)
        XCTAssertEqual(cached.value.value, 42)
        XCTAssertEqual(cached.statusCode, 304)
        XCTAssertEqual(cached.cacheOutcome, .revalidated304)
        XCTAssertEqual(cached.rateLimit.remaining, 4_999)

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].authorization, "Bearer top-secret")
        XCTAssertEqual(requests[0].accept, "application/vnd.github+json")
        XCTAssertEqual(requests[0].apiVersion, "2022-11-28")
        XCTAssertNil(requests[0].ifNoneMatch)
        XCTAssertEqual(requests[1].ifNoneMatch, #""v1""#)
        XCTAssertEqual(requests[1].cachePolicy, URLRequest.CachePolicy.reloadIgnoringLocalAndRemoteCacheData.rawValue)

        let debug = await client.debugEntries()
        XCTAssertEqual(debug.map(\.statusCode), [200, 304])
        XCTAssertEqual(debug.map(\.cacheOutcome), [.stored200, .revalidated304])
        XCTAssertFalse(debug.map(\.sanitizedURL).joined().contains("Owner"))
        XCTAssertFalse(debug.map(\.sanitizedURL).joined().contains("Private"))
        XCTAssertFalse(debugDescription(debug).contains("top-secret"))
    }

    func test304WithoutCachedBodyFailsExplicitly() async throws {
        let canonicalURL = try GitHubURLCanonicalizer.canonicalURL(baseURL: baseURL, endpoint: endpoint)
        let store = MemoryGitHubStore(
            cache: [canonicalURL.absoluteString: .init(etag: #""v1""#, body: nil)]
        )
        let transport = ScriptedGitHubTransport(steps: [
            .response(status: 304, headers: rateHeaders(remaining: 4_999), body: Data())
        ])
        let client = GitHubClient(store: store, transport: transport, baseURL: baseURL)

        do {
            _ = try await client.get(TestPayload.self, endpoint: endpoint, token: "secret")
            XCTFail("Expected missing cached body")
        } catch let error as GitHubClientError {
            XCTAssertEqual(error, .missingCachedBody)
        }

        let debug = await client.debugEntries()
        XCTAssertEqual(debug.last?.statusCode, 304)
        XCTAssertEqual(debug.last?.errorCategory, .cache)
    }

    func testETagReplacementIsUsedByNextRequest() async throws {
        let store = MemoryGitHubStore()
        let transport = ScriptedGitHubTransport(steps: [
            .response(status: 200, headers: rateHeaders(etag: #""v1""#), body: payload),
            .response(status: 200, headers: rateHeaders(etag: #""v2""#), body: payload),
            .response(status: 304, headers: rateHeaders(), body: Data())
        ])
        let client = GitHubClient(store: store, transport: transport, baseURL: baseURL)

        _ = try await client.get(TestPayload.self, endpoint: endpoint, token: "secret")
        _ = try await client.get(TestPayload.self, endpoint: endpoint, token: "secret")
        _ = try await client.get(TestPayload.self, endpoint: endpoint, token: "secret")

        let requests = await transport.capturedRequests()
        XCTAssertNil(requests[0].ifNoneMatch)
        XCTAssertEqual(requests[1].ifNoneMatch, #""v1""#)
        XCTAssertEqual(requests[2].ifNoneMatch, #""v2""#)
    }

    func testCachePersistsAcrossClientAndStoreRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitHubClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runbar.sqlite3").path

        let firstTransport = ScriptedGitHubTransport(steps: [
            .response(status: 200, headers: rateHeaders(etag: #""persistent""#), body: payload)
        ])
        let firstClient = GitHubClient(
            store: try SQLiteGitHubStore(path: path),
            transport: firstTransport,
            baseURL: baseURL
        )
        _ = try await firstClient.get(TestPayload.self, endpoint: endpoint, token: "secret")

        let secondTransport = ScriptedGitHubTransport(steps: [
            .response(status: 304, headers: rateHeaders(), body: Data())
        ])
        let secondClient = GitHubClient(
            store: try SQLiteGitHubStore(path: path),
            transport: secondTransport,
            baseURL: baseURL
        )
        let response = try await secondClient.get(TestPayload.self, endpoint: endpoint, token: "secret")

        XCTAssertEqual(response.value.value, 42)
        XCTAssertEqual(response.statusCode, 304)
        let requests = await secondTransport.capturedRequests()
        XCTAssertEqual(requests.first?.ifNoneMatch, #""persistent""#)
    }

    func testPrimaryAndSecondaryLimitsUseBoundedRetryTimingAndCaptureHeaders() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let primarySleeper = RecordingGitHubSleeper()
        let primaryTransport = ScriptedGitHubTransport(steps: Array(repeating:
            .response(
                status: 403,
                headers: [
                    "x-ratelimit-remaining": "0",
                    "x-ratelimit-reset": String(Int(fixedNow.timeIntervalSince1970 + 30))
                ],
                body: Data(#"{"message":"rate limit"}"#.utf8)
            ),
            count: 3
        ))
        let primaryClient = GitHubClient(
            store: MemoryGitHubStore(),
            transport: primaryTransport,
            sleeper: primarySleeper,
            baseURL: baseURL,
            maximumRetryCount: 2,
            maximumBackoff: 20,
            now: { fixedNow }
        )

        do {
            _ = try await primaryClient.get(TestPayload.self, endpoint: endpoint, token: "secret")
            XCTFail("Expected primary rate limit")
        } catch let error as GitHubClientError {
            XCTAssertEqual(error, .primaryRateLimit(retryAt: fixedNow.addingTimeInterval(30)))
        }
        let primaryDelays = await primarySleeper.delays()
        XCTAssertEqual(primaryDelays, [20, 20])
        let primaryDebug = await primaryClient.debugEntries()
        XCTAssertEqual(primaryDebug.count, 3)
        XCTAssertEqual(primaryDebug.map(\.errorCategory), Array(repeating: .primaryRateLimit, count: 3))
        XCTAssertEqual(primaryDebug.map(\.rateLimit.remaining), Array(repeating: 0, count: 3))

        let secondarySleeper = RecordingGitHubSleeper()
        let secondaryTransport = ScriptedGitHubTransport(steps: Array(repeating:
            .response(
                status: 429,
                headers: ["Retry-After": "7", "x-ratelimit-remaining": "712"],
                body: Data(#"{"message":"secondary rate limit"}"#.utf8)
            ),
            count: 2
        ))
        let secondaryClient = GitHubClient(
            store: MemoryGitHubStore(),
            transport: secondaryTransport,
            sleeper: secondarySleeper,
            baseURL: baseURL,
            maximumRetryCount: 1
        )

        do {
            _ = try await secondaryClient.get(TestPayload.self, endpoint: endpoint, token: "secret")
            XCTFail("Expected secondary rate limit")
        } catch let error as GitHubClientError {
            XCTAssertEqual(error, .secondaryRateLimit(retryAfter: 7))
        }
        let secondaryDelays = await secondarySleeper.delays()
        XCTAssertEqual(secondaryDelays, [7])
    }

    func testRepository403Or404MarksInaccessibleOnceAndStopsFutureRequests() async throws {
        for status in [403, 404] {
            let store = MemoryGitHubStore()
            let transport = ScriptedGitHubTransport(steps: [
                .response(status: status, headers: rateHeaders(remaining: 4_800), body: Data())
            ])
            let client = GitHubClient(store: store, transport: transport, baseURL: baseURL)

            do {
                _ = try await client.get(
                    TestPayload.self,
                    endpoint: endpoint,
                    token: "secret",
                    repositoryKey: "owner/repo-\(status)"
                )
                XCTFail("Expected access denial")
            } catch let error as GitHubClientError {
                XCTAssertEqual(
                    error,
                    .accessDenied(repositoryKey: "owner/repo-\(status)", firstNotice: true)
                )
            }

            do {
                _ = try await client.get(
                    TestPayload.self,
                    endpoint: endpoint,
                    token: "secret",
                    repositoryKey: "owner/repo-\(status)"
                )
                XCTFail("Expected future polling to remain cancelled")
            } catch let error as GitHubClientError {
                XCTAssertEqual(
                    error,
                    .accessDenied(repositoryKey: "owner/repo-\(status)", firstNotice: false)
                )
            }
            let capturedCount = await transport.capturedRequests().count
            XCTAssertEqual(capturedCount, 1)
        }
    }

    func testExplicitAccessResetAllowsOneConditionalRetry() async throws {
        let store = MemoryGitHubStore()
        let transport = ScriptedGitHubTransport(steps: [
            .response(status: 404, headers: rateHeaders(remaining: 4_800), body: Data()),
            .response(
                status: 200,
                headers: rateHeaders(etag: "v1", remaining: 4_799),
                body: payload
            )
        ])
        let client = GitHubClient(store: store, transport: transport, baseURL: baseURL)

        do {
            _ = try await client.get(
                TestPayload.self,
                endpoint: endpoint,
                token: "secret",
                repositoryKey: "owner/retry"
            )
            XCTFail("Expected initial access denial")
        } catch let error as GitHubClientError {
            XCTAssertEqual(error, .accessDenied(repositoryKey: "owner/retry", firstNotice: true))
        }

        try await client.resetRepositoryAccess("owner/retry")
        let response = try await client.get(
            TestPayload.self,
            endpoint: endpoint,
            token: "secret",
            repositoryKey: "owner/retry"
        )

        XCTAssertEqual(response.value.value, 42)
        XCTAssertEqual(response.statusCode, 200)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testAuthenticationDecodingTransportAndMissingETagCategoriesAreDistinct() async throws {
        let cases: [(ScriptedGitHubTransport.Step, GitHubClientError, GitHubErrorCategory, Int?)] = [
            (
                .response(status: 401, headers: rateHeaders(remaining: 123), body: Data()),
                .authentication,
                .authentication,
                401
            ),
            (
                .response(status: 200, headers: rateHeaders(etag: #""v1""#), body: Data("not json".utf8)),
                .decoding,
                .decoding,
                200
            ),
            (
                .response(status: 200, headers: rateHeaders(), body: payload),
                .missingETag,
                .cache,
                200
            ),
            (.failure, .transport, .transport, nil)
        ]

        for (step, expectedError, expectedCategory, expectedStatus) in cases {
            let client = GitHubClient(
                store: MemoryGitHubStore(),
                transport: ScriptedGitHubTransport(steps: [step]),
                baseURL: baseURL
            )
            do {
                _ = try await client.get(TestPayload.self, endpoint: endpoint, token: "secret")
                XCTFail("Expected \(expectedError)")
            } catch let error as GitHubClientError {
                XCTAssertEqual(error, expectedError)
            }
            let debug = await client.debugEntries()
            XCTAssertEqual(debug.last?.errorCategory, expectedCategory)
            XCTAssertEqual(debug.last?.statusCode, expectedStatus)
        }
    }

    func testDebugLogIsBoundedToOneHundredEntries() async throws {
        let canonicalURL = try GitHubURLCanonicalizer.canonicalURL(baseURL: baseURL, endpoint: endpoint)
        let store = MemoryGitHubStore(
            cache: [canonicalURL.absoluteString: .init(etag: #""v1""#, body: payload)]
        )
        let transport = ScriptedGitHubTransport(steps: Array(repeating:
            .response(status: 304, headers: rateHeaders(remaining: 4_999), body: Data()),
            count: 105
        ))
        let client = GitHubClient(store: store, transport: transport, baseURL: baseURL)

        for _ in 0..<105 {
            _ = try await client.get(TestPayload.self, endpoint: endpoint, token: "secret")
        }

        let debugCount = await client.debugEntries().count
        XCTAssertEqual(debugCount, 100)
    }

    private func rateHeaders(
        etag: String? = nil,
        remaining: Int = 4_999
    ) -> [String: String] {
        var headers = [
            "x-ratelimit-remaining": String(remaining),
            "x-ratelimit-reset": "1700003600"
        ]
        headers["ETag"] = etag
        return headers
    }

    private func debugDescription(_ entries: [GitHubDebugEntry]) -> String {
        entries.map {
            "\($0.timestamp)|\($0.sanitizedURL)|\($0.statusCode.map(String.init) ?? "nil")|" +
            "\($0.cacheOutcome.rawValue)|\($0.rateLimit.remaining.map(String.init) ?? "nil")|" +
            "\($0.errorCategory?.rawValue ?? "none")"
        }.joined(separator: "\n")
    }
}

private struct TestPayload: Codable, Equatable, Sendable {
    let value: Int
}

private actor MemoryGitHubStore: GitHubClientStoring {
    private var cache: [String: GitHubCachedResponse]
    private var inaccessible: Set<String> = []
    private var debug: [GitHubDebugEntry] = []

    init(cache: [String: GitHubCachedResponse] = [:]) {
        self.cache = cache
    }

    func cachedResponse(for canonicalURL: String) async throws -> GitHubCachedResponse? {
        cache[canonicalURL]
    }

    func saveCachedResponse(_ response: GitHubCachedResponse, for canonicalURL: String) async throws {
        cache[canonicalURL] = response
    }

    func isRepositoryAccessible(_ repositoryKey: String) async throws -> Bool {
        !inaccessible.contains(repositoryKey)
    }

    func markRepositoryInaccessible(_ repositoryKey: String) async throws -> Bool {
        inaccessible.insert(repositoryKey).inserted
    }

    func setRepositoryAccessible(_ isAccessible: Bool, repositoryKey: String) async throws {
        if isAccessible { inaccessible.remove(repositoryKey) }
        else { inaccessible.insert(repositoryKey) }
    }

    func appendDebugEntry(_ entry: GitHubDebugEntry) async throws {
        debug.append(entry)
    }

    func clearDebugEntries() async throws {
        debug.removeAll()
    }
}

private actor ScriptedGitHubTransport: GitHubTransport {
    enum Step: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
        case failure
    }

    struct CapturedRequest: Sendable {
        let url: String
        let authorization: String?
        let accept: String?
        let apiVersion: String?
        let ifNoneMatch: String?
        let cachePolicy: UInt
    }

    private var steps: [Step]
    private var requests: [CapturedRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(
            CapturedRequest(
                url: request.url?.absoluteString ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                accept: request.value(forHTTPHeaderField: "Accept"),
                apiVersion: request.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
                ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match"),
                cachePolicy: request.cachePolicy.rawValue
            )
        )
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        switch step {
        case let .response(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (body, response)
        case .failure:
            throw URLError(.notConnectedToInternet)
        }
    }

    func capturedRequests() -> [CapturedRequest] {
        requests
    }
}

private actor RecordingGitHubSleeper: GitHubRetrySleeping {
    private var recordedDelays: [TimeInterval] = []

    func sleep(seconds: TimeInterval) async throws {
        recordedDelays.append(seconds)
    }

    func delays() -> [TimeInterval] {
        recordedDelays
    }
}
