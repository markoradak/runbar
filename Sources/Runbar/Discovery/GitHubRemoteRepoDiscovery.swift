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

        let endpoint = GitHubEndpoint(
            pathSegments: ["user", "repos"],
            queryItems: [
                .init(name: "sort", value: "pushed"),
                .init(name: "direction", value: "desc"),
                .init(name: "per_page", value: "100")
            ]
        )
        let payload: [GitHubRepositoryResponse]
        do {
            payload = try await client.get(
                [GitHubRepositoryResponse].self,
                endpoint: endpoint,
                token: token
            ).value
        } catch let error as GitHubClientError {
            throw map(error)
        } catch {
            throw RepoDiscoveryError.remoteTransport
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

private struct GitHubRepositoryResponse: Decodable, Sendable {
    let fullName: String
    let pushedAt: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case pushedAt = "pushed_at"
    }
}
