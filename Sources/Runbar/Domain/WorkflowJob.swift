import Foundation

struct WorkflowJobStep: Identifiable, Equatable, Sendable {
    let number: Int
    let name: String
    let status: String
    let conclusion: String?

    var id: Int { number }
}

struct WorkflowJob: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let htmlURL: String?
    let steps: [WorkflowJobStep]

    var executingStep: WorkflowJobStep? {
        steps.first(where: { $0.status == "in_progress" })
    }
}

struct WorkflowJobsResult: Equatable, Sendable {
    let jobs: [WorkflowJob]
    let rateLimit: GitHubRateLimit
}

enum WorkflowJobsState: Equatable, Sendable {
    case idle
    case loading
    case loaded([WorkflowJob])
    case failed(String)
}

protocol WorkflowJobsLoading: Sendable {
    func loadJobs(for run: MenuBarRun, token: String) async throws -> WorkflowJobsResult
}

actor GitHubWorkflowJobsLoader: WorkflowJobsLoading {
    private let client: GitHubClient

    init(client: GitHubClient) {
        self.client = client
    }

    func loadJobs(for run: MenuBarRun, token: String) async throws -> WorkflowJobsResult {
        let response = try await client.get(
            GitHubJobsPayload.self,
            endpoint: .actionsJobs(repository: run.repository, runID: run.id, perPage: 100),
            token: token,
            repositoryKey: run.run.repositoryKey
        )
        return WorkflowJobsResult(
            jobs: response.value.jobs.map(WorkflowJob.init(payload:)),
            rateLimit: response.rateLimit
        )
    }
}

private struct GitHubJobsPayload: Decodable, Sendable {
    let jobs: [GitHubJobPayload]
}

private struct GitHubJobPayload: Decodable, Sendable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let htmlURL: String?
    let steps: [GitHubJobStepPayload]?

    private enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case htmlURL = "html_url"
    }
}

private struct GitHubJobStepPayload: Decodable, Sendable {
    let number: Int
    let name: String
    let status: String
    let conclusion: String?
}

private extension WorkflowJob {
    init(payload: GitHubJobPayload) {
        self.init(
            id: payload.id,
            name: payload.name,
            status: payload.status,
            conclusion: payload.conclusion,
            htmlURL: payload.htmlURL,
            steps: (payload.steps ?? []).map {
                WorkflowJobStep(
                    number: $0.number,
                    name: $0.name,
                    status: $0.status,
                    conclusion: $0.conclusion
                )
            }
        )
    }
}
