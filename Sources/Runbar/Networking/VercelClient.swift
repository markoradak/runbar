import Foundation

struct VercelClient: ExternalProviderClient {
    /// How long the account census — who the token belongs to, which scopes it
    /// can see, and how many projects that is — stays usable before it is walked
    /// again. None of it changes between two polls minutes apart, but together
    /// it is every request a poll makes except the deployments themselves:
    /// `/v2/user`, `/v2/teams`, and up to 50 pages of `/v9/projects` per scope.
    /// Caching it is what makes a tight poll cadence affordable — a warm poll
    /// costs one request per scope instead of an entire account walk.
    static let censusTTL: TimeInterval = 15 * 60

    let provider = ExecutionProvider.vercel
    private let transport: any ProviderTransport
    private let baseURL: URL
    private let now: @Sendable () -> Date
    private let census = AccountCensusCache()

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
        let account: VercelAccountCensus
        if let cached = await census.value(token: token, at: now(), ttl: Self.censusTTL) {
            account = cached
        } else {
            account = try await loadCensus(token: token)
            await census.store(account, token: token, at: now())
        }

        // The only per-poll work: the recent deployments in each scope. A warm
        // census means a revoked token is no longer caught by `/v2/user` — the
        // deployments call returns the same 401 and raises the same error, so
        // nothing is lost but a request.
        var executions: [ProviderExecution] = []
        var lastRateLimit = ProviderRateLimit.unknown
        for scope in account.scopes {
            var query = [URLQueryItem(name: "limit", value: "20")]
            if let id = scope.id { query.append(URLQueryItem(name: "teamId", value: id)) }
            let result: ProviderHTTPResult<VercelDeploymentsEnvelope> = try await get(
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
            accountLabel: account.accountLabel,
            executions: deduplicated,
            projectCount: account.projectCount,
            rateLimit: lastRateLimit,
            fetchedAt: now()
        )
    }

    /// Walks the account: who the token belongs to, every scope it can reach,
    /// and how many distinct projects that adds up to.
    private func loadCensus(token: String) async throws -> VercelAccountCensus {
        let user: VercelUserEnvelope = try await get(path: "/v2/user", token: token).value
        let teams: VercelTeamsEnvelope = try await get(
            path: "/v2/teams",
            query: [URLQueryItem(name: "limit", value: "100")],
            token: token
        ).value

        let personal = VercelScope(id: nil, slug: user.user.username ?? user.user.email ?? "personal")
        let scopes = [personal] + teams.teams.map {
            VercelScope(id: $0.id, slug: $0.slug ?? $0.name ?? $0.id)
        }

        // The status card reports how many projects the token can see. Recent
        // deployments only cover the one or two projects that were just deployed,
        // so counting *those* (as this client used to) shows "1 project" for an
        // account with dozens. Page through the real projects list per scope and
        // union the IDs so a project visible in both the personal and a team
        // scope is counted once.
        var projectIDs: Set<String> = []
        for scope in scopes {
            var from: String?
            for _ in 0 ..< 50 {
                var query = [URLQueryItem(name: "limit", value: "100")]
                if let id = scope.id { query.append(URLQueryItem(name: "teamId", value: id)) }
                if let from { query.append(URLQueryItem(name: "from", value: from)) }
                let result: ProviderHTTPResult<VercelProjectsEnvelope> = try await get(
                    path: "/v9/projects",
                    query: query,
                    token: token
                )
                let known = projectIDs.count
                projectIDs.formUnion(result.value.projects.map(\.id))
                // Stop at the last page, or if a page adds nothing new (guards a
                // cursor that fails to advance).
                guard let next = result.value.pagination?.next, projectIDs.count > known else { break }
                from = next
            }
        }

        return VercelAccountCensus(
            accountLabel: user.user.username ?? user.user.email ?? "Vercel",
            scopes: scopes,
            projectCount: projectIDs.count
        )
    }

    private func execution(from item: VercelDeployment, scope: VercelScope) -> ProviderExecution? {
        guard let createdAt = ProviderDateParser.milliseconds(item.created) else { return nil }
        let state = item.readyState ?? item.state ?? "QUEUED"
        let normalized = normalize(state: state)
        // Vercel auto-cancels a deployment when the project's watched paths did
        // not change (its "ignored build step" — common in a monorepo where a
        // push touched a different app). Such a deployment never builds, so it
        // has no `buildingAt`, and Vercel omits it from its own dashboard. Drop
        // it rather than surface a phantom cancelled run the user never sees on
        // Vercel.
        if normalized.conclusion == "cancelled", item.buildingAt == nil { return nil }
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
            webURL: urlValue,
            previewURL: item.url.map { "https://" + $0 }
        )
    }

    /// Returns build-log lines for a deployment (newest last). The events
    /// endpoint requires the owning scope's teamId, which is not stored, so try
    /// the personal scope first and then each team until one accepts.
    func logLines(externalID: String, projectKey _: String, token: String) async throws -> [String] {
        let teamsResponse: ProviderHTTPResult<VercelTeamsEnvelope> = try await get(
            path: "/v2/teams",
            query: [URLQueryItem(name: "limit", value: "100")],
            token: token
        )
        let teamIDs: [String?] = [nil] + teamsResponse.value.teams.map { $0.id }
        var lastError: ProviderClientError = .invalidResponse
        for teamID in teamIDs {
            var query = [
                URLQueryItem(name: "direction", value: "backward"),
                URLQueryItem(name: "limit", value: "100")
            ]
            if let teamID { query.append(URLQueryItem(name: "teamId", value: teamID)) }
            do {
                let result: ProviderHTTPResult<[VercelDeploymentEvent]> = try await get(
                    path: "/v3/deployments/\(externalID)/events",
                    query: query,
                    token: token
                )
                // Backward direction returns newest first; restore log order.
                return result.value
                    .compactMap { $0.payload?.text ?? $0.text }
                    .reversed()
            } catch let error as ProviderClientError {
                lastError = error
            }
        }
        throw lastError
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

private struct VercelScope: Sendable {
    let id: String?
    let slug: String
}

/// The account shape behind a token: everything a poll needs that is not the
/// deployments themselves.
private struct VercelAccountCensus: Sendable {
    let accountLabel: String
    let scopes: [VercelScope]
    let projectCount: Int
}

/// Holds the last census so `fetch` can skip re-walking the account. Keyed by a
/// fingerprint rather than the token itself, so reconnecting with a different
/// token re-walks instead of reporting the previous account's scopes, without
/// keeping a second copy of the credential in memory.
private actor AccountCensusCache {
    private var fingerprint: Int?
    private var census: VercelAccountCensus?
    private var fetchedAt: Date?

    func value(token: String, at now: Date, ttl: TimeInterval) -> VercelAccountCensus? {
        guard let census, let fetchedAt, fingerprint == token.hashValue,
              now.timeIntervalSince(fetchedAt) < ttl
        else { return nil }
        return census
    }

    func store(_ census: VercelAccountCensus, token: String, at now: Date) {
        self.census = census
        fingerprint = token.hashValue
        fetchedAt = now
    }
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

private struct VercelProjectsEnvelope: Decodable, Sendable {
    let projects: [VercelProject]
    let pagination: VercelPagination?
}

private struct VercelProject: Decodable, Sendable {
    let id: String
}

private struct VercelPagination: Decodable, Sendable {
    let next: String?

    private enum CodingKeys: String, CodingKey { case next }

    // Vercel returns `next` as a millisecond timestamp on some endpoints and an
    // opaque continuation token on others; accept either and stringify it so it
    // can be handed back as the `from` query parameter.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? container.decode(Int64.self, forKey: .next) {
            next = String(number)
        } else {
            next = try? container.decode(String.self, forKey: .next)
        }
    }
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

private struct VercelDeploymentEvent: Decodable, Sendable {
    let type: String?
    let text: String?
    let payload: VercelDeploymentEventPayload?
}

private struct VercelDeploymentEventPayload: Decodable, Sendable {
    let text: String?
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
