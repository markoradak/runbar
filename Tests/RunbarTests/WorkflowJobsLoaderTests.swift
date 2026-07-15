import Foundation
import XCTest
@testable import Runbar

final class WorkflowJobsLoaderTests: XCTestCase {
    func testLazyJobsLoaderUsesBoundedEndpointAndExplicit304Reuse() async throws {
        let body = Data(
            """
            {
              "total_count": 1,
              "jobs": [{
                "id": 501,
                "name": "build",
                "status": "in_progress",
                "conclusion": null,
                "html_url": "https://github.com/owner/repo/actions/runs/42/job/501",
                "steps": [
                  {"number": 1, "name": "Checkout", "status": "completed", "conclusion": "success"},
                  {"number": 2, "name": "Compile", "status": "in_progress", "conclusion": null}
                ]
              }]
            }
            """.utf8
        )
        let url = URL(string: "https://api.github.com/repos/owner/repo/actions/runs/42/jobs?per_page=100")!
        let transport = JobsSequenceTransport(
            responses: [
                (
                    body,
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["ETag": "jobs-v1", "x-ratelimit-remaining": "700"]
                    )!
                ),
                (
                    Data(),
                    HTTPURLResponse(
                        url: url,
                        statusCode: 304,
                        httpVersion: nil,
                        headerFields: ["x-ratelimit-remaining": "700"]
                    )!
                )
            ]
        )
        let store = JobsMemoryGitHubStore()
        let client = GitHubClient(store: store, transport: transport)
        let loader = GitHubWorkflowJobsLoader(client: client)
        let run = menuRun()

        let first = try await loader.loadJobs(for: run, token: "jobs-token-marker")
        let second = try await loader.loadJobs(for: run, token: "jobs-token-marker")
        let requests = await transport.requests()

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, url.absoluteString)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "jobs-v1")
        XCTAssertEqual(first.jobs, second.jobs)
        XCTAssertEqual(first.jobs.first?.executingStep?.name, "Compile")
        XCTAssertEqual(second.rateLimit.remaining, 700)
        let savedResponseCount = await store.savedResponseCount()
        XCTAssertEqual(savedResponseCount, 1)
    }

    private func menuRun() -> MenuBarRun {
        let now = Date(timeIntervalSince1970: 1_000)
        return MenuBarRun(
            run: WorkflowRun(
                id: 42,
                repositoryKey: "owner/repo",
                workflowID: 9,
                workflowName: "CI",
                status: "in_progress",
                conclusion: nil,
                runStartedAt: now,
                createdAt: now,
                updatedAt: now,
                headBranch: "main",
                headSHA: "abc",
                event: "push",
                displayTitle: "CI",
                htmlURL: "https://github.com/owner/repo/actions/runs/42",
                runAttempt: 1,
                actorLogin: nil,
                triggeringActorLogin: nil
            ),
            repository: RepoIdentity(owner: "owner", name: "repo"),
            matchesLocalHEAD: false
        )
    }
}

private actor JobsSequenceTransport: GitHubTransport {
    private var queued: [(Data, HTTPURLResponse)]
    private var captured: [URLRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) {
        queued = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !queued.isEmpty else { throw GitHubClientError.transport }
        return queued.removeFirst()
    }

    func requests() -> [URLRequest] { captured }
}

private actor JobsMemoryGitHubStore: GitHubClientStoring {
    private var cache: [String: GitHubCachedResponse] = [:]
    private var savedCount = 0

    func cachedResponse(for canonicalURL: String) async throws -> GitHubCachedResponse? {
        cache[canonicalURL]
    }

    func saveCachedResponse(_ response: GitHubCachedResponse, for canonicalURL: String) async throws {
        cache[canonicalURL] = response
        savedCount += 1
    }

    func isRepositoryAccessible(_ repositoryKey: String) async throws -> Bool { true }
    func markRepositoryInaccessible(_ repositoryKey: String) async throws -> Bool { true }
    func appendDebugEntry(_ entry: GitHubDebugEntry) async throws {}
    func clearDebugEntries() async throws {}
    func savedResponseCount() -> Int { savedCount }
}
