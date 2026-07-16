import Foundation

protocol RemoteRepositoryDiscovering: Sendable {
    func discover(token: String) async throws -> [RemoteRepository]
}

struct GitHubRemoteRepoDiscovery: RemoteRepositoryDiscovering {
    private let client: GitHubClient

    init(client: GitHubClient) {
        self.client = client
    }

    func discover(token: String) async throws -> [RemoteRepository] {
        guard !token.isEmpty else { throw RepoDiscoveryError.remoteUnauthorized }

        let installations = try await loadInstallations(token: token)

        var payload: [GitHubRepositoryResponse] = []
        for installation in installations {
            payload.append(contentsOf: try await loadRepositories(installationID: installation.id, token: token))
        }

        let repositories = payload.compactMap { item -> RemoteRepository? in
            let parts = item.fullName.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return RemoteRepository(
                identity: RepoIdentity(owner: String(parts[0]), name: String(parts[1])),
                pushedAt: item.pushedAt.flatMap(Self.parseGitHubDate)
            )
        }

        return repositories.sorted { lhs, rhs in
            let leftDate = lhs.pushedAt ?? .distantPast
            let rightDate = rhs.pushedAt ?? .distantPast
            if leftDate == rightDate {
                return lhs.identity.normalizedKey < rhs.identity.normalizedKey
            }
            return leftDate > rightDate
        }
        .prefix(30)
        .map { $0 }
    }

    private func loadInstallations(token: String) async throws -> [GitHubInstallationResponse] {
        var page = 1
        var installations: [GitHubInstallationResponse] = []
        while true {
            let response: GitHubInstallationsResponse = try await get(
                GitHubInstallationsResponse.self,
                endpoint: GitHubEndpoint(
                    pathSegments: ["user", "installations"],
                    queryItems: [
                        .init(name: "page", value: String(page)),
                        .init(name: "per_page", value: "100")
                    ]
                ),
                token: token
            )
            installations.append(contentsOf: response.installations)
            guard installations.count < response.totalCount, !response.installations.isEmpty else { break }
            page += 1
        }
        return installations
    }

    private func loadRepositories(
        installationID: Int64,
        token: String
    ) async throws -> [GitHubRepositoryResponse] {
        var page = 1
        var repositories: [GitHubRepositoryResponse] = []
        while true {
            let response: GitHubInstallationRepositoriesResponse = try await get(
                GitHubInstallationRepositoriesResponse.self,
                endpoint: GitHubEndpoint(
                    pathSegments: ["user", "installations", String(installationID), "repositories"],
                    queryItems: [
                        .init(name: "page", value: String(page)),
                        .init(name: "per_page", value: "100")
                    ]
                ),
                token: token
            )
            repositories.append(contentsOf: response.repositories)
            guard repositories.count < response.totalCount, !response.repositories.isEmpty else { break }
            page += 1
        }
        return repositories
    }

    private func get<Response: Decodable & Sendable>(
        _ type: Response.Type,
        endpoint: GitHubEndpoint,
        token: String
    ) async throws -> Response {
        do {
            return try await client.get(type, endpoint: endpoint, token: token).value
        } catch let error as GitHubClientError {
            throw map(error)
        } catch {
            throw RepoDiscoveryError.remoteTransport
        }
    }

    private func map(_ error: GitHubClientError) -> RepoDiscoveryError {
        switch error {
        case .authentication:
            .remoteUnauthorized
        case .primaryRateLimit, .secondaryRateLimit:
            .remoteForbidden
        case .decoding:
            .invalidRemoteResponse
        case .transport:
            .remoteTransport
        case let .unexpectedStatus(status):
            .remoteStatus(status)
        case .invalidURL, .missingETag, .missingCachedBody, .persistence, .accessDenied:
            .persistence(error.userMessage)
        }
    }

    private static func parseGitHubDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct GitHubInstallationsResponse: Decodable, Sendable {
    let totalCount: Int
    let installations: [GitHubInstallationResponse]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case installations
    }
}

private struct GitHubInstallationResponse: Decodable, Sendable {
    let id: Int64
}

private struct GitHubInstallationRepositoriesResponse: Decodable, Sendable {
    let totalCount: Int
    let repositories: [GitHubRepositoryResponse]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case repositories
    }
}

private struct GitHubRepositoryResponse: Decodable, Sendable {
    let fullName: String
    let pushedAt: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case pushedAt = "pushed_at"
    }
}
