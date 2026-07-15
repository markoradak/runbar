import Foundation
import SQLite3
import XCTest
@testable import Runbar

final class GitHubRunPollerTests: XCTestCase {
    private let baseURL = URL(string: "https://api.github.test")!
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)

    func testPollUsesBoundedRunsEndpointPersistsFieldsAndRevalidatesExplicitly() async throws {
        let store = CombinedRunPollStore()
        let transport = RunPollTransport(steps: [
            .response(status: 200, headers: rateHeaders(etag: #""runs-v1""#), body: activePayload),
            .response(status: 304, headers: rateHeaders(), body: Data())
        ])
        let client = GitHubClient(store: store, transport: transport, baseURL: baseURL)
        let pollNow = fixedNow
        let poller = GitHubRunPoller(client: client, store: store, now: { pollNow })
        let repository = PollRepository(
            key: "owner/repo",
            identity: RepoIdentity(owner: "Owner", name: "Repo"),
            pushedAt: nil
        )

        let fresh = try await poller.poll(repository: repository, token: "secret-marker")
        let cached = try await poller.poll(repository: repository, token: "secret-marker")

        XCTAssertEqual(fresh.statusCode, 200)
        XCTAssertEqual(fresh.cacheOutcome, .stored200)
        XCTAssertTrue(fresh.hasActiveRun)
        XCTAssertEqual(fresh.runs.first?.workflowID, 77)
        XCTAssertEqual(fresh.runs.first?.runStartedAt, Date(timeIntervalSince1970: 1_699_999_940))
        XCTAssertEqual(cached.statusCode, 304)
        XCTAssertEqual(cached.cacheOutcome, .revalidated304)
        XCTAssertEqual(cached.runs, fresh.runs)

        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.url), [
            "https://api.github.test/repos/Owner/Repo/actions/runs?per_page=20",
            "https://api.github.test/repos/Owner/Repo/actions/runs?per_page=20"
        ])
        XCTAssertNil(requests[0].ifNoneMatch)
        XCTAssertEqual(requests[1].ifNoneMatch, #""runs-v1""#)
        let savedRuns = await store.savedRuns()
        XCTAssertEqual(savedRuns.count, 1)
        XCTAssertEqual(savedRuns.first?.headSHA, "abc123")
        XCTAssertEqual(savedRuns.first?.actorLogin, "octocat")
        let debugDescription = String(describing: await client.debugEntries())
        XCTAssertFalse(debugDescription.contains("secret-marker"))
    }

    func testRunHistorySurvivesDiscoveryRefreshOfRetainedRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarM3HistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runbar.sqlite3").path
        let discoveryStore = try SQLiteStore(path: path)
        let pollStore = try SQLitePollStore(path: path)
        let current = Date()
        let repository = discoveredRepository(pushedAt: current)
        try await discoveryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(codeRootPath: nil, repositories: [repository], skippedLocalRepositories: [])
        )
        try await pollStore.saveWorkflowRuns([workflowRun(at: current)], for: repository.id)

        let refreshed = discoveredRepository(pushedAt: current.addingTimeInterval(60))
        try await discoveryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(codeRootPath: nil, repositories: [refreshed], skippedLocalRepositories: [])
        )

        XCTAssertEqual(try scalarInt(path: path, sql: "SELECT COUNT(*) FROM runs"), 1)
        XCTAssertEqual(try scalarInt(path: path, sql: "SELECT COUNT(*) FROM repos"), 1)
    }

    private var activePayload: Data {
        Data(
            #"{"total_count":1,"workflow_runs":[{"id":123,"workflow_id":77,"name":"CI","status":"in_progress","conclusion":null,"run_started_at":"2023-11-14T22:12:20Z","created_at":"2023-11-14T22:12:00Z","updated_at":"2023-11-14T22:13:00Z","head_branch":"main","head_sha":"abc123","event":"push","display_title":"Build","html_url":"https://github.test/Owner/Repo/actions/runs/123","run_attempt":1,"actor":{"login":"octocat"},"triggering_actor":{"login":"hubot"}}]}"#.utf8
        )
    }

    private func rateHeaders(etag: String? = nil) -> [String: String] {
        var headers = [
            "x-ratelimit-remaining": "4998",
            "x-ratelimit-reset": "1700003600"
        ]
        headers["ETag"] = etag
        return headers
    }

    private func discoveredRepository(pushedAt: Date) -> DiscoveredRepository {
        DiscoveredRepository(
            identity: RepoIdentity(owner: "Owner", name: "Repo"),
            source: .remote,
            localPath: nil,
            pushedAt: pushedAt,
            workflows: [],
            isExcluded: false,
            isAccessible: true
        )
    }

    private func workflowRun(at date: Date? = nil) -> WorkflowRun {
        let timestamp = date ?? fixedNow
        return WorkflowRun(
            id: 123,
            repositoryKey: "owner/repo",
            workflowID: 77,
            workflowName: "CI",
            status: "completed",
            conclusion: "success",
            runStartedAt: timestamp.addingTimeInterval(-120),
            createdAt: timestamp.addingTimeInterval(-150),
            updatedAt: timestamp,
            headBranch: "main",
            headSHA: "abc123",
            event: "push",
            displayTitle: "Build",
            htmlURL: "https://github.test/Owner/Repo/actions/runs/123",
            runAttempt: 1,
            actorLogin: "octocat",
            triggeringActorLogin: "hubot"
        )
    }

    private func scalarInt(path: String, sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw SQLiteStoreError.open("test read failed") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw SQLiteStoreError.statement("test query failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteStoreError.step("test query returned no row")
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}

private actor CombinedRunPollStore: GitHubClientStoring, WorkflowRunStoring {
    private var cache: [String: GitHubCachedResponse] = [:]
    private var runs: [WorkflowRun] = []
    private var debug: [GitHubDebugEntry] = []

    func cachedResponse(for canonicalURL: String) async throws -> GitHubCachedResponse? {
        cache[canonicalURL]
    }

    func saveCachedResponse(_ response: GitHubCachedResponse, for canonicalURL: String) async throws {
        cache[canonicalURL] = response
    }

    func isRepositoryAccessible(_: String) async throws -> Bool { true }
    func markRepositoryInaccessible(_: String) async throws -> Bool { true }
    func setRepositoryAccessible(_ isAccessible: Bool, repositoryKey: String) async throws {}

    func appendDebugEntry(_ entry: GitHubDebugEntry) async throws {
        debug.append(entry)
    }

    func clearDebugEntries() async throws {
        debug.removeAll()
    }

    func saveWorkflowRuns(_ runs: [WorkflowRun], for _: String) async throws {
        self.runs = runs
    }

    func savedRuns() -> [WorkflowRun] {
        runs
    }
}

private actor RunPollTransport: GitHubTransport {
    enum Step: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
    }

    struct Request: Sendable {
        let url: String
        let ifNoneMatch: String?
    }

    private var steps: [Step]
    private var captured: [Request] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(
            Request(
                url: request.url?.absoluteString ?? "",
                ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match")
            )
        )
        guard !steps.isEmpty else { throw GitHubClientError.transport }
        switch steps.removeFirst() {
        case let .response(status, headers, body):
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
            )
        }
    }

    func requests() -> [Request] {
        captured
    }
}
