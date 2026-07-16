import Foundation

struct ProviderRateLimit: Equatable, Sendable {
    let remaining: Int?
    let resetAt: Date?

    static let unknown = ProviderRateLimit(remaining: nil, resetAt: nil)
}

struct ProviderFetchResult: Equatable, Sendable {
    let provider: ExecutionProvider
    let accountLabel: String
    let executions: [ProviderExecution]
    let projectCount: Int
    let rateLimit: ProviderRateLimit
    let fetchedAt: Date
}

struct ProviderExecution: Equatable, Sendable {
    let provider: ExecutionProvider
    let externalID: String
    let repository: RepoIdentity
    let projectKey: String
    let projectName: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let headBranch: String?
    let headSHA: String
    let environment: String
    let displayTitle: String
    let webURL: String
    let previewURL: String?

    init(
        provider: ExecutionProvider,
        externalID: String,
        repository: RepoIdentity,
        projectKey: String,
        projectName: String,
        status: String,
        conclusion: String?,
        startedAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        headBranch: String?,
        headSHA: String,
        environment: String,
        displayTitle: String,
        webURL: String,
        previewURL: String? = nil
    ) {
        self.provider = provider
        self.externalID = externalID
        self.repository = repository
        self.projectKey = projectKey
        self.projectName = projectName
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.environment = environment
        self.displayTitle = displayTitle
        self.webURL = webURL
        self.previewURL = previewURL
    }

    var syntheticID: Int64 {
        StableProviderID.run(provider: provider, externalID: externalID)
    }

    var workflowID: Int64 {
        StableProviderID.workflow(provider: provider, projectKey: projectKey)
    }

    var repositoryKey: String { repository.normalizedKey }

    var workflowRun: WorkflowRun {
        WorkflowRun(
            id: syntheticID,
            repositoryKey: repositoryKey,
            workflowID: workflowID,
            workflowName: projectName,
            status: status,
            conclusion: conclusion,
            runStartedAt: startedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            headBranch: headBranch,
            headSHA: headSHA,
            event: environment,
            displayTitle: displayTitle,
            htmlURL: webURL,
            runAttempt: 1,
            actorLogin: nil,
            triggeringActorLogin: nil,
            provider: provider,
            externalID: externalID,
            previewURL: previewURL,
            projectKey: projectKey
        )
    }
}

enum ProviderConnectionState: Equatable, Sendable {
    case disconnected
    case validating
    case connected(accountLabel: String, projectCount: Int)
    case failed(message: String, hasStoredCredential: Bool)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var hasStoredCredential: Bool {
        switch self {
        case .connected, .validating: true
        case let .failed(_, hasStoredCredential): hasStoredCredential
        case .disconnected: false
        }
    }
}

struct ProviderMonitorSnapshot: Equatable, Sendable {
    var connections: [ExecutionProvider: ProviderConnectionState]
    var lastSyncAt: Date?
    var isRefreshing: Bool
    var activeExecutionCount: Int
    var rateLimits: [ExecutionProvider: ProviderRateLimit]
    /// True while a provider is low on quota or is serving a `Retry-After`, so
    /// polling has been widened. Surfaced next to the GitHub-side degraded
    /// state (docs/ARCHITECTURE.md, invariant 5).
    var isRateLimitDegraded: Bool

    static let idle = ProviderMonitorSnapshot(
        connections: [
            .vercel: .disconnected,
            .cloudflarePages: .disconnected
        ],
        lastSyncAt: nil,
        isRefreshing: false,
        activeExecutionCount: 0,
        rateLimits: [:],
        isRateLimitDegraded: false
    )

    var hasConnectedProvider: Bool {
        connections.values.contains(where: \.isConnected)
    }
}

enum ProviderClientError: Error, Equatable, Sendable {
    case authentication
    case permissionDenied(String)
    case rateLimited(retryAt: Date?)
    case invalidResponse
    case transport
    case persistence

    var userMessage: String {
        switch self {
        case .authentication:
            "The provider rejected this token. Create a new read-only token and try again."
        case let .permissionDenied(message):
            message
        case .rateLimited:
            "The provider rate limit was reached. Runbar will back off automatically."
        case .invalidResponse:
            "The provider returned an unexpected response."
        case .transport:
            "Runbar could not reach the provider."
        case .persistence:
            "Runbar could not save provider executions locally."
        }
    }
}

protocol ExternalProviderClient: Sendable {
    var provider: ExecutionProvider { get }
    func fetch(token: String) async throws -> ProviderFetchResult
    /// Returns the raw log lines of an execution (newest last), capped by the
    /// provider client to a reasonable amount for tail display.
    func logLines(externalID: String, projectKey: String, token: String) async throws -> [String]
}

protocol ProviderExecutionStoring: Sendable {
    func saveProviderExecutions(_ executions: [ProviderExecution], provider: ExecutionProvider) async throws
    func deleteProviderExecutions(provider: ExecutionProvider) async throws
}

enum StableProviderID {
    static func run(provider: ExecutionProvider, externalID: String) -> Int64 {
        let value = hash(provider.rawValue + ":run:" + externalID) | (1 << 63)
        return Int64(bitPattern: value)
    }

    static func workflow(provider: ExecutionProvider, projectKey: String) -> Int64 {
        Int64(bitPattern: hash(provider.rawValue + ":project:" + projectKey) & 0x7fff_ffff_ffff_ffff)
    }

    private static func hash(_ value: String) -> UInt64 {
        var result: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            result ^= UInt64(byte)
            result &*= 1_099_511_628_211
        }
        return result
    }
}

enum ProviderDateParser {
    static func iso8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func milliseconds(_ value: Int64?) -> Date? {
        value.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}
