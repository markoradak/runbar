import Foundation

protocol RemoteRepositoryDiscovering: Sendable {
    func discover(token: String) async throws -> [RemoteRepository]
}

struct GitHubRemoteRepoDiscovery: RemoteRepositoryDiscovering {
    private static let endpoint = URL(string: "https://api.github.com/user/repos?sort=pushed&direction=desc&per_page=100")!

    private let transport: any AuthTransport
    private let endpoint: URL

    init(
        transport: any AuthTransport = URLSessionAuthTransport.live(),
        endpoint: URL = GitHubRemoteRepoDiscovery.endpoint
    ) {
        self.transport = transport
        self.endpoint = endpoint
    }

    func discover(token: String) async throws -> [RemoteRepository] {
        guard !token.isEmpty else { throw RepoDiscoveryError.remoteUnauthorized }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw RepoDiscoveryError.remoteTransport
        }

        switch response.statusCode {
        case 200:
            break
        case 401:
            throw RepoDiscoveryError.remoteUnauthorized
        case 403:
            throw RepoDiscoveryError.remoteForbidden
        default:
            throw RepoDiscoveryError.remoteStatus(response.statusCode)
        }

        guard let payload = try? JSONDecoder().decode([GitHubRepositoryResponse].self, from: data) else {
            throw RepoDiscoveryError.invalidRemoteResponse
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

    private static func parseGitHubDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct GitHubRepositoryResponse: Decodable {
    let fullName: String
    let pushedAt: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case pushedAt = "pushed_at"
    }
}
