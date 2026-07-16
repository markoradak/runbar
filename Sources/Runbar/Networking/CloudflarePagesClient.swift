import Foundation

struct CloudflarePagesClient: ExternalProviderClient {
    let provider = ExecutionProvider.cloudflarePages
    private let transport: any ProviderTransport
    private let baseURL: URL
    private let now: @Sendable () -> Date

    init(
        transport: any ProviderTransport = URLSessionProviderTransport.live(),
        baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.now = now
    }

    func fetch(token: String) async throws -> ProviderFetchResult {
        let verification: CloudflareEnvelope<CloudflareTokenStatus> = try await get(
            path: "/user/tokens/verify",
            token: token
        ).value
        guard verification.success, verification.result.status == "active" else {
            throw ProviderClientError.authentication
        }

        let accountsResult: ProviderHTTPResult<CloudflareEnvelope<[CloudflareAccount]>> = try await get(
            path: "/accounts",
            query: [URLQueryItem(name: "per_page", value: "50")],
            token: token
        )
        guard accountsResult.value.success else { throw ProviderClientError.invalidResponse }

        var executions: [ProviderExecution] = []
        var lastRateLimit = accountsResult.rateLimit
        var projectCount = 0
        for account in accountsResult.value.result {
            let projectsResult: ProviderHTTPResult<CloudflareEnvelope<[CloudflareProject]>> = try await get(
                path: "/accounts/\(account.id)/pages/projects",
                query: [URLQueryItem(name: "per_page", value: "100")],
                token: token
            )
            lastRateLimit = projectsResult.rateLimit
            guard projectsResult.value.success else { continue }
            projectCount += projectsResult.value.result.count
            executions.append(contentsOf: projectsResult.value.result.compactMap { project in
                guard let deployment = project.latestDeployment else { return nil }
                return execution(from: deployment, project: project, account: account)
            })
        }

        let accountLabel: String
        if accountsResult.value.result.count == 1 {
            accountLabel = accountsResult.value.result[0].name
        } else {
            accountLabel = "\(accountsResult.value.result.count) Cloudflare accounts"
        }
        return ProviderFetchResult(
            provider: .cloudflarePages,
            accountLabel: accountLabel,
            executions: executions,
            projectCount: projectCount,
            rateLimit: lastRateLimit,
            fetchedAt: now()
        )
    }

    private func execution(
        from deployment: CloudflareDeployment,
        project: CloudflareProject,
        account: CloudflareAccount
    ) -> ProviderExecution? {
        guard let createdAt = ProviderDateParser.iso8601(deployment.createdOn) else { return nil }
        let stage = deployment.latestStage
        let normalized = normalize(stage: stage, isSkipped: deployment.isSkipped)
        let metadata = deployment.deploymentTrigger?.metadata
        let source = project.source?.config
        let repository = RepoIdentity(
            owner: source?.owner ?? account.name,
            name: source?.repoName ?? project.name
        )
        let startedAt = ProviderDateParser.iso8601(stage?.startedOn) ?? createdAt
        let updatedAt = ProviderDateParser.iso8601(stage?.endedOn)
            ?? ProviderDateParser.iso8601(deployment.modifiedOn)
            ?? startedAt
        return ProviderExecution(
            provider: .cloudflarePages,
            externalID: deployment.id,
            repository: repository,
            projectKey: account.id + "/" + project.name,
            projectName: project.name,
            status: normalized.status,
            conclusion: normalized.conclusion,
            startedAt: startedAt,
            createdAt: createdAt,
            updatedAt: max(updatedAt, createdAt),
            headBranch: metadata?.branch,
            headSHA: metadata?.commitHash ?? "",
            environment: (deployment.environment ?? "deployment").capitalized,
            displayTitle: metadata?.commitMessage ?? project.name,
            webURL: deployment.url ?? "https://dash.cloudflare.com",
            previewURL: deployment.url
        )
    }

    /// Returns build-log lines for a deployment (newest last). The account is
    /// recovered from `projectKey`, which is stored as "accountID/projectName".
    func logLines(externalID: String, projectKey: String, token: String) async throws -> [String] {
        guard let separator = projectKey.firstIndex(of: "/") else {
            throw ProviderClientError.invalidResponse
        }
        let accountID = String(projectKey[..<separator])
        let projectName = String(projectKey[projectKey.index(after: separator)...])
        let result: ProviderHTTPResult<CloudflareLogsEnvelope> = try await get(
            path: "/accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(externalID)/history/logs",
            token: token
        )
        guard result.value.success else { throw ProviderClientError.invalidResponse }
        return (result.value.result?.data ?? []).map(\.line)
    }

    private func normalize(
        stage: CloudflareStage?,
        isSkipped: Bool?
    ) -> (status: String, conclusion: String?) {
        if isSkipped == true { return ("completed", "skipped") }
        switch stage?.status.lowercased() {
        case "success": return ("completed", "success")
        case "failure": return ("completed", "failure")
        case "canceled", "cancelled": return ("completed", "cancelled")
        case "active": return ("in_progress", nil)
        default:
            if ["build", "deploy"].contains(stage?.name.lowercased() ?? "") {
                return ("in_progress", nil)
            }
            return ("queued", nil)
        }
    }

    private func get<T: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = [],
        token: String
    ) async throws -> ProviderHTTPResult<T> {
        try await ProviderHTTP.get(
            baseURL: baseURL,
            path: path,
            query: query,
            token: token,
            transport: transport
        )
    }
}

private struct CloudflareLogsEnvelope: Decodable, Sendable {
    let success: Bool
    let result: CloudflareLogsResult?
}

private struct CloudflareLogsResult: Decodable, Sendable {
    let data: [CloudflareLogLine]?
}

private struct CloudflareLogLine: Decodable, Sendable {
    let line: String
}

private struct CloudflareEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let result: Result
}

private struct CloudflareTokenStatus: Decodable, Sendable {
    let status: String
}

private struct CloudflareAccount: Decodable, Sendable {
    let id: String
    let name: String
}

private struct CloudflareProject: Decodable, Sendable {
    let name: String
    let source: CloudflareProjectSource?
    let latestDeployment: CloudflareDeployment?

    private enum CodingKeys: String, CodingKey {
        case name, source
        case latestDeployment = "latest_deployment"
    }
}

private struct CloudflareProjectSource: Decodable, Sendable {
    let config: CloudflareProjectSourceConfig?
}

private struct CloudflareProjectSourceConfig: Decodable, Sendable {
    let owner: String?
    let repoName: String?

    private enum CodingKeys: String, CodingKey {
        case owner
        case repoName = "repo_name"
    }
}

private struct CloudflareDeployment: Decodable, Sendable {
    let id: String
    let url: String?
    let environment: String?
    let createdOn: String?
    let modifiedOn: String?
    let isSkipped: Bool?
    let latestStage: CloudflareStage?
    let deploymentTrigger: CloudflareDeploymentTrigger?

    private enum CodingKeys: String, CodingKey {
        case id, url, environment
        case createdOn = "created_on"
        case modifiedOn = "modified_on"
        case isSkipped = "is_skipped"
        case latestStage = "latest_stage"
        case deploymentTrigger = "deployment_trigger"
    }
}

private struct CloudflareStage: Decodable, Sendable {
    let name: String
    let status: String
    let startedOn: String?
    let endedOn: String?

    private enum CodingKeys: String, CodingKey {
        case name, status
        case startedOn = "started_on"
        case endedOn = "ended_on"
    }
}

private struct CloudflareDeploymentTrigger: Decodable, Sendable {
    let metadata: CloudflareDeploymentMetadata?
}

private struct CloudflareDeploymentMetadata: Decodable, Sendable {
    let branch: String?
    let commitHash: String?
    let commitMessage: String?

    private enum CodingKeys: String, CodingKey {
        case branch
        case commitHash = "commit_hash"
        case commitMessage = "commit_message"
    }
}
