import Foundation

protocol WorkflowRunStoring: Sendable {
    func saveWorkflowRuns(_ runs: [WorkflowRun], for repositoryKey: String) async throws
}

actor GitHubRunPoller: RunPolling {
    private let client: GitHubClient
    private let store: any WorkflowRunStoring
    private let now: @Sendable () -> Date

    init(
        client: GitHubClient,
        store: any WorkflowRunStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.store = store
        self.now = now
    }

    func poll(repository: PollRepository, token: String) async throws -> RepositoryPollResult {
        let response = try await client.get(
            GitHubActionsRunsResponse.self,
            endpoint: .actionsRuns(repository: repository.identity, perPage: 20),
            token: token,
            repositoryKey: repository.key
        )

        let runs: [WorkflowRun]
        do {
            runs = try response.value.workflowRuns.map { item in
                guard let createdAt = GitHubDateParser.parse(item.createdAt),
                      let updatedAt = GitHubDateParser.parse(item.updatedAt)
                else { throw GitHubClientError.decoding }
                return WorkflowRun(
                    id: item.id,
                    repositoryKey: repository.key,
                    workflowID: item.workflowID,
                    workflowName: item.name ?? item.displayTitle,
                    status: item.status,
                    conclusion: item.conclusion,
                    runStartedAt: item.runStartedAt.flatMap(GitHubDateParser.parse),
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    headBranch: item.headBranch,
                    headSHA: item.headSHA,
                    event: item.event,
                    displayTitle: item.displayTitle,
                    htmlURL: item.htmlURL,
                    runAttempt: item.runAttempt,
                    actorLogin: item.actor?.login,
                    triggeringActorLogin: item.triggeringActor?.login
                )
            }
            try await store.saveWorkflowRuns(runs, for: repository.key)
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.persistence
        }

        return RepositoryPollResult(
            runs: runs,
            statusCode: response.statusCode,
            cacheOutcome: response.cacheOutcome,
            rateLimit: response.rateLimit,
            fetchedAt: now()
        )
    }
}

private struct GitHubActionsRunsResponse: Decodable, Sendable {
    let workflowRuns: [GitHubWorkflowRunResponse]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct GitHubWorkflowRunResponse: Decodable, Sendable {
    let id: Int64
    let workflowID: Int64
    let name: String?
    let status: String
    let conclusion: String?
    let runStartedAt: String?
    let createdAt: String
    let updatedAt: String
    let headBranch: String?
    let headSHA: String
    let event: String
    let displayTitle: String
    let htmlURL: String
    let runAttempt: Int
    let actor: GitHubActorResponse?
    let triggeringActor: GitHubActorResponse?

    enum CodingKeys: String, CodingKey {
        case id
        case workflowID = "workflow_id"
        case name
        case status
        case conclusion
        case runStartedAt = "run_started_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case headBranch = "head_branch"
        case headSHA = "head_sha"
        case event
        case displayTitle = "display_title"
        case htmlURL = "html_url"
        case runAttempt = "run_attempt"
        case actor
        case triggeringActor = "triggering_actor"
    }
}

private struct GitHubActorResponse: Decodable, Sendable {
    let login: String
}

private enum GitHubDateParser {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
