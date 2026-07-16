import Foundation

enum ExecutionProvider: String, CaseIterable, Codable, Hashable, Sendable {
    case githubActions = "github_actions"
    case vercel
    case cloudflarePages = "cloudflare_pages"

    var displayName: String {
        switch self {
        case .githubActions: "GitHub Actions"
        case .vercel: "Vercel"
        case .cloudflarePages: "Cloudflare Pages"
        }
    }

    var shortName: String {
        switch self {
        case .githubActions: "GitHub"
        case .vercel: "Vercel"
        case .cloudflarePages: "Cloudflare"
        }
    }

    var systemImage: String {
        switch self {
        case .githubActions: "chevron.left.forwardslash.chevron.right"
        case .vercel: "triangle.fill"
        case .cloudflarePages: "cloud.fill"
        }
    }
}

struct WorkflowRun: Equatable, Sendable {
    let id: Int64
    let repositoryKey: String
    let workflowID: Int64
    let workflowName: String
    let status: String
    let conclusion: String?
    let runStartedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let headBranch: String?
    let headSHA: String
    let event: String
    let displayTitle: String
    let htmlURL: String
    let runAttempt: Int
    let actorLogin: String?
    let triggeringActorLogin: String?
    let provider: ExecutionProvider
    let externalID: String
    let previewURL: String?

    init(
        id: Int64,
        repositoryKey: String,
        workflowID: Int64,
        workflowName: String,
        status: String,
        conclusion: String?,
        runStartedAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        headBranch: String?,
        headSHA: String,
        event: String,
        displayTitle: String,
        htmlURL: String,
        runAttempt: Int,
        actorLogin: String?,
        triggeringActorLogin: String?,
        provider: ExecutionProvider = .githubActions,
        externalID: String? = nil,
        previewURL: String? = nil
    ) {
        self.id = id
        self.repositoryKey = repositoryKey
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.status = status
        self.conclusion = conclusion
        self.runStartedAt = runStartedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.event = event
        self.displayTitle = displayTitle
        self.htmlURL = htmlURL
        self.runAttempt = runAttempt
        self.actorLogin = actorLogin
        self.triggeringActorLogin = triggeringActorLogin
        self.provider = provider
        self.externalID = externalID ?? String(id)
        self.previewURL = previewURL
    }

    var isActive: Bool {
        status == "queued" || status == "in_progress"
    }

    var completedAt: Date? {
        status == "completed" ? updatedAt : nil
    }

    var supportsJobs: Bool { provider == .githubActions }

    /// Cloudflare Pages has no deployment-cancel API; GitHub and Vercel do.
    var supportsCancel: Bool { provider != .cloudflarePages }

    /// Only GitHub Actions runs can be re-run in place.
    var supportsRerun: Bool { provider == .githubActions }
}
