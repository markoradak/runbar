import Foundation

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

    var isActive: Bool {
        status == "queued" || status == "in_progress"
    }

    var completedAt: Date? {
        status == "completed" ? updatedAt : nil
    }
}
