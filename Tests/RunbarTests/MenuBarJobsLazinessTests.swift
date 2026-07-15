import XCTest
@testable import Runbar

@MainActor
final class MenuBarJobsLazinessTests: XCTestCase {
    func testJobsAreFetchedOnlyOnFirstExpansion() async throws {
        let credentialStore = JobsCredentialStore(token: "jobs-token-marker")
        let loader = CountingJobsLoader()
        let model = SettingsModel(
            credentialStore: credentialStore,
            authValidator: JobsAuthValidator(),
            workflowJobsLoader: loader
        )
        let run = activeMenuRun()

        let requestsBeforeExpansion = await loader.requestCount()
        XCTAssertEqual(requestsBeforeExpansion, 0)
        XCTAssertEqual(model.jobsState(for: run.id), .idle)

        model.expandJobs(for: run)
        for _ in 0..<200 {
            if case .loaded = model.jobsState(for: run.id) { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        guard case let .loaded(jobs) = model.jobsState(for: run.id) else {
            return XCTFail("Expected jobs to load after expansion")
        }
        XCTAssertEqual(jobs.first?.executingStep?.name, "Compile")
        let requestsAfterExpansion = await loader.requestCount()
        XCTAssertEqual(requestsAfterExpansion, 1)
        XCTAssertEqual(credentialStore.readCount, 1)

        model.expandJobs(for: run)
        try await Task.sleep(for: .milliseconds(5))
        let requestsAfterSecondExpansion = await loader.requestCount()
        XCTAssertEqual(requestsAfterSecondExpansion, 1)
        XCTAssertEqual(credentialStore.readCount, 1)
    }

    private func activeMenuRun() -> MenuBarRun {
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

private actor CountingJobsLoader: WorkflowJobsLoading {
    private var count = 0

    func loadJobs(for run: MenuBarRun, token: String) async throws -> WorkflowJobsResult {
        count += 1
        return WorkflowJobsResult(
            jobs: [
                WorkflowJob(
                    id: 7,
                    name: "build",
                    status: "in_progress",
                    conclusion: nil,
                    htmlURL: nil,
                    steps: [
                        WorkflowJobStep(
                            number: 2,
                            name: "Compile",
                            status: "in_progress",
                            conclusion: nil
                        )
                    ]
                )
            ],
            rateLimit: GitHubRateLimit(remaining: 700, resetAt: nil)
        )
    }

    func requestCount() -> Int { count }
}

private final class JobsCredentialStore: CredentialStore {
    var token: String?
    private(set) var readCount = 0

    init(token: String?) {
        self.token = token
    }

    func readToken() throws -> String? {
        readCount += 1
        return token
    }

    func saveToken(_ token: String) throws { self.token = token }
    func deleteToken() throws { token = nil }
}

private actor JobsAuthValidator: AuthValidating {
    func validate(token: String) async throws -> AuthenticatedUser {
        AuthenticatedUser(login: "unused")
    }
}
