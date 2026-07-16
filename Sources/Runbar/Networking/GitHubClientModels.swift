import Foundation

struct GitHubQueryItem: Hashable, Sendable {
    let name: String
    let value: String?
}

struct GitHubEndpoint: Hashable, Sendable {
    let pathSegments: [String]
    let queryItems: [GitHubQueryItem]

    init(pathSegments: [String], queryItems: [GitHubQueryItem] = []) {
        self.pathSegments = pathSegments
        self.queryItems = queryItems
    }

    static func actionsRuns(repository: RepoIdentity, perPage: Int = 1) -> GitHubEndpoint {
        GitHubEndpoint(
            pathSegments: ["repos", repository.owner, repository.name, "actions", "runs"],
            queryItems: [.init(name: "per_page", value: String(perPage))]
        )
    }

    static func actionsJobs(
        repository: RepoIdentity,
        runID: Int64,
        perPage: Int = 100
    ) -> GitHubEndpoint {
        GitHubEndpoint(
            pathSegments: [
                "repos", repository.owner, repository.name, "actions", "runs",
                String(runID), "jobs"
            ],
            queryItems: [.init(name: "per_page", value: String(perPage))]
        )
    }
}

enum GitHubURLCanonicalizer {
    static func canonicalURL(baseURL: URL, endpoint: GitHubEndpoint) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubClientError.invalidURL
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encodedSegments = try endpoint.pathSegments.map { segment -> String in
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw GitHubClientError.invalidURL
            }
            return encoded
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([basePath] + encodedSegments)
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        let sortedItems = endpoint.queryItems.sorted {
            if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
            return $0.name < $1.name
        }
        components.queryItems = sortedItems.map { URLQueryItem(name: $0.name, value: $0.value) }
        components.fragment = nil

        guard let url = components.url else { throw GitHubClientError.invalidURL }
        return url
    }

    static func sanitizedURL(_ canonicalURL: URL) -> String {
        guard var components = URLComponents(url: canonicalURL, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        components.user = nil
        components.password = nil
        components.fragment = nil

        var segments = components.path.split(separator: "/").map(String.init)
        if segments.count >= 3, segments[0].lowercased() == "repos" {
            segments[1] = "<owner>"
            segments[2] = "<repo>"
            components.path = "/" + segments.joined(separator: "/")
        }

        let sensitiveNames = ["access_token", "authorization", "client_secret", "code", "signature", "token"]
        components.queryItems = components.queryItems?.map { item in
            sensitiveNames.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "<redacted>")
                : item
        }
        return components.string ?? "<invalid-url>"
    }
}

struct GitHubRateLimit: Equatable, Sendable {
    let remaining: Int?
    let resetAt: Date?
}

enum GitHubCacheOutcome: String, Codable, Sendable {
    case stored200 = "stored_200"
    case revalidated304 = "revalidated_304"
    case none
}

enum GitHubErrorCategory: String, Codable, Sendable {
    case authentication
    case primaryRateLimit = "primary_rate_limit"
    case secondaryRateLimit = "secondary_rate_limit"
    case accessDenied = "access_denied"
    case decoding
    case transport
    case cache
    case invalidResponse = "invalid_response"
    case unexpectedStatus = "unexpected_status"
}

struct GitHubDebugEntry: Equatable, Sendable {
    let timestamp: Date
    let sanitizedURL: String
    let statusCode: Int?
    let cacheOutcome: GitHubCacheOutcome
    let rateLimit: GitHubRateLimit
    let errorCategory: GitHubErrorCategory?
}

struct GitHubCachedResponse: Equatable, Sendable {
    let etag: String
    let body: Data?
}

struct GitHubResponse<Value: Sendable>: Sendable {
    let value: Value
    let statusCode: Int
    let cacheOutcome: GitHubCacheOutcome
    let rateLimit: GitHubRateLimit
}

enum GitHubRunAction: String, Sendable {
    case rerun
    case cancel
}

enum GitHubClientError: Error, Equatable, Sendable {
    case invalidURL
    case authentication
    case primaryRateLimit(retryAt: Date?)
    case secondaryRateLimit(retryAfter: TimeInterval?)
    case accessDenied(repositoryKey: String, firstNotice: Bool)
    case missingETag
    case missingCachedBody
    case decoding
    case transport
    case persistence
    case unexpectedStatus(Int)

    var category: GitHubErrorCategory {
        switch self {
        case .invalidURL: .invalidResponse
        case .authentication: .authentication
        case .primaryRateLimit: .primaryRateLimit
        case .secondaryRateLimit: .secondaryRateLimit
        case .accessDenied: .accessDenied
        case .missingETag, .missingCachedBody, .persistence: .cache
        case .decoding: .decoding
        case .transport: .transport
        case .unexpectedStatus: .unexpectedStatus
        }
    }

    var userMessage: String {
        switch self {
        case .authentication:
            "GitHub rejected the saved credential."
        case .primaryRateLimit:
            "GitHub's primary rate limit is exhausted; Runbar paused requests."
        case .secondaryRateLimit:
            "GitHub asked Runbar to slow down; requests are backing off."
        case .accessDenied:
            "This repository is not included in an accessible Runbar GitHub App installation."
        case .missingETag:
            "GitHub did not provide the ETag required for safe polling."
        case .missingCachedBody:
            "GitHub returned 304 but Runbar has no matching cached response body."
        case .decoding:
            "GitHub returned an unexpected response payload."
        case .transport:
            "Runbar could not reach GitHub."
        case .persistence:
            "Runbar could not persist its explicit GitHub response cache."
        case .invalidURL, .unexpectedStatus:
            "GitHub returned an unexpected response."
        }
    }
}
