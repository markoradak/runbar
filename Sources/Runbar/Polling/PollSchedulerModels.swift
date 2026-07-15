import Foundation

enum PollingTier: String, Codable, CaseIterable, Sendable {
    case hot
    case warm
    case cold

    var baseInterval: TimeInterval {
        switch self {
        case .hot: 8
        case .warm: 60
        case .cold: 10 * 60
        }
    }
}

enum PollTrigger: String, Codable, Sendable {
    case launch
    case wake
    case scheduled
    case manual
    case localPush = "local_push"
}

struct PollRepository: Equatable, Sendable {
    let key: String
    let identity: RepoIdentity
    let pushedAt: Date?
}

struct RepositoryPollResult: Equatable, Sendable {
    let runs: [WorkflowRun]
    let statusCode: Int
    let cacheOutcome: GitHubCacheOutcome
    let rateLimit: GitHubRateLimit
    let fetchedAt: Date

    var hasActiveRun: Bool {
        runs.contains(where: \.isActive)
    }

    var latestCompletionAt: Date? {
        runs.compactMap(\.completedAt).max()
    }
}

struct PollRepositorySnapshot: Equatable, Identifiable, Sendable {
    let repositoryKey: String
    let tier: PollingTier
    let nextPollAt: Date
    let lastPollAt: Date?
    let hasActiveRun: Bool

    var id: String { repositoryKey }
}

struct PollSchedulerSnapshot: Equatable, Sendable {
    let isRunning: Bool
    let isRateLimitDegraded: Bool
    let hasAuthenticationFailure: Bool
    let rateLimit: GitHubRateLimit
    let lastSyncAt: Date?
    let totalPollAttempts: Int
    let quotaConsumingRequests: Int
    let sessionStartedAt: Date?
    let sessionRepositoryCount: Int
    let observedActiveRun: Bool
    let repositories: [PollRepositorySnapshot]

    static let idle = PollSchedulerSnapshot(
        isRunning: false,
        isRateLimitDegraded: false,
        hasAuthenticationFailure: false,
        rateLimit: GitHubRateLimit(remaining: nil, resetAt: nil),
        lastSyncAt: nil,
        totalPollAttempts: 0,
        quotaConsumingRequests: 0,
        sessionStartedAt: nil,
        sessionRepositoryCount: 0,
        observedActiveRun: false,
        repositories: []
    )

    var tierCounts: [PollingTier: Int] {
        Dictionary(grouping: repositories, by: \.tier).mapValues(\.count)
    }
}

struct PollSchedulerEvent: Equatable, Sendable {
    let timestamp: Date
    let repositoryKey: String
    let trigger: PollTrigger
    let tierBefore: PollingTier
    let tierAfter: PollingTier
    let scheduledInterval: TimeInterval
    let jitterFactor: Double
    let statusCode: Int?
    let cacheOutcome: GitHubCacheOutcome
    let rateLimit: GitHubRateLimit
    let hadActiveRun: Bool
    let isRateLimitDegraded: Bool
    let errorCategory: GitHubErrorCategory?
}

enum PollSchedulerError: Error, Equatable, Sendable {
    case missingCredential
}
