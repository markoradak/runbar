import Foundation

struct VercelClient: ExternalProviderClient {
    let provider = ExecutionProvider.vercel
    private let transport: any ProviderTransport
    private let baseURL: URL
    private let now: @Sendable () -> Date

    init(
        transport: any ProviderTransport = URLSessionProviderTransport.live(),
        baseURL: URL = URL(string: "https://api.vercel.com")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.now = now
    }

    func fetch(token: String) async throws -> ProviderFetchResult {
        let user: VercelUserEnvelope = try await get(path: "/v2/user", token: token).value
        let teamsResponse: HTTPResult<VercelTeamsEnvelope> = try await get(
            path: "/v2/teams",
            query: [URLQueryItem(name: "limit", value: "100")],
            token: token
        )

        let personal = VercelScope(id: nil, slug: user.user.username ?? user.user.email ?? "personal")
        let scopes = [personal] + teamsResponse.value.teams.map {
            VercelScope(id: $0.id, slug: $0.slug ?? $0.name ?? $0.id)
        }

        var executions: [ProviderExecution] = []
        var lastRateLimit = teamsResponse.rateLimit
        for scope in scopes {
            var query = [URLQueryItem(name: "limit", value: "20")]
            if let id = scope.id { query.append(URLQueryItem(name: "teamId", value: id)) }
            let result: HTTPResult<VercelDeploymentsEnvelope> = try await get(
                path: "/v6/deployments",
                query: query,
                token: token
            )
            lastRateLimit = result.rateLimit
            executions.append(contentsOf: result.value.deployments.compactMap {
                execution(from: $0, scope: scope)
            })
        }

        let deduplicated = Dictionary(grouping: executions, by: \.externalID)
            .compactMap { $0.value.max(by: { $0.updatedAt < $1.updatedAt }) }
        return ProviderFetchResult(
            provider: .vercel,
            accountLabel: user.user.username ?? user.user.email ?? "Vercel",
            executions: deduplicated,
            projectCount: Set(deduplicated.map(\.projectKey)).count,
            rateLimit: lastRateLimit,
            fetchedAt: now()
        )
    }

    private func execution(from item: VercelDeployment, scope: VercelScope) -> ProviderExecution? {
        guard let createdAt = ProviderDateParser.milliseconds(item.created) else { return nil }
        let state = item.readyState ?? item.state ?? "QUEUED"
        let normalized = normalize(state: state)
        let repository = RepoIdentity(
            owner: item.meta?.githubCommitOrg ?? scope.slug,
            name: item.meta?.githubCommitRepo ?? item.name
        )
        let startedAt = ProviderDateParser.milliseconds(item.buildingAt) ?? createdAt
        let updatedAt = ProviderDateParser.milliseconds(item.ready) ?? startedAt
        let target = item.target?.capitalized ?? "Deployment"
        let urlValue = item.inspectorURL ?? item.url.map { "https://" + $0 } ?? "https://vercel.com"
        return ProviderExecution(
            provider: .vercel,
            externalID: item.uid,
            repository: repository,
            projectKey: item.projectID ?? scope.slug + "/" + item.name,
            projectName: item.name,
            status: normalized.status,
            conclusion: normalized.conclusion,
            startedAt: startedAt,
            createdAt: createdAt,
            updatedAt: max(updatedAt, createdAt),
            headBranch: item.meta?.githubCommitRef,
            headSHA: item.meta?.githubCommitSHA ?? "",
            environment: target,
            displayTitle: item.meta?.githubCommitMessage ?? item.name,
            webURL: urlValue
        )
    }

    private func normalize(state: String) -> (status: String, conclusion: String?) {
        switch state.uppercased() {
        case "READY": ("completed", "success")
        case "ERROR": ("completed", "failure")
        case "CANCELED", "CANCELLED": ("completed", "cancelled")
        case "BUILDING": ("in_progress", nil)
        default: ("queued", nil)
        }
    }

    private func get<T: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = [],
        token: String
    ) async throws -> HTTPResult<T> {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw ProviderClientError.invalidResponse }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ProviderClientError.invalidResponse }
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(ProviderHTTP.request(url: url, token: token)) }
        catch let error as ProviderClientError { throw error }
        catch { throw ProviderClientError.transport }
        try ProviderHTTP.validate(response)
        do {
            return HTTPResult(
                value: try JSONDecoder().decode(T.self, from: data),
                rateLimit: ProviderHTTP.rateLimit(from: response)
            )
        } catch {
            throw ProviderClientError.invalidResponse
        }
    }
}

private struct HTTPResult<Value: Sendable>: Sendable {
    let value: Value
    let rateLimit: ProviderRateLimit
}

private struct VercelScope: Sendable {
    let id: String?
    let slug: String
}

private struct VercelUserEnvelope: Decodable, Sendable {
    let user: VercelUser
}

private struct VercelUser: Decodable, Sendable {
    let username: String?
    let email: String?
}

private struct VercelTeamsEnvelope: Decodable, Sendable {
    let teams: [VercelTeam]
}

private struct VercelTeam: Decodable, Sendable {
    let id: String
    let slug: String?
    let name: String?
}

private struct VercelDeploymentsEnvelope: Decodable, Sendable {
    let deployments: [VercelDeployment]
}

private struct VercelDeployment: Decodable, Sendable {
    let uid: String
    let name: String
    let url: String?
    let inspectorURL: String?
    let created: Int64?
    let buildingAt: Int64?
    let ready: Int64?
    let state: String?
    let readyState: String?
    let projectID: String?
    let target: String?
    let meta: VercelDeploymentMeta?

    private enum CodingKeys: String, CodingKey {
        case uid, name, url, created, buildingAt, ready, state, readyState, target, meta
        case inspectorURL = "inspectorUrl"
        case projectID = "projectId"
    }
}

private struct VercelDeploymentMeta: Decodable, Sendable {
    let githubCommitOrg: String?
    let githubCommitRepo: String?
    let githubCommitSHA: String?
    let githubCommitRef: String?
    let githubCommitMessage: String?

    private enum CodingKeys: String, CodingKey {
        case githubCommitOrg, githubCommitRepo, githubCommitRef, githubCommitMessage
        case githubCommitSHA = "githubCommitSha"
    }
}
