import Foundation

struct RepoIdentity: Hashable, Codable, Sendable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }
    var normalizedKey: String { fullName.lowercased() }
}

struct WorkflowMetadata: Hashable, Codable, Sendable {
    let fileName: String
    let name: String
    let events: [String]
}

enum RepositorySource: String, Codable, Sendable {
    case local
    case remote
    case both
}

struct LocalRepository: Hashable, Sendable {
    let identity: RepoIdentity
    let localPath: String
    let workflows: [WorkflowMetadata]
}

struct RemoteRepository: Hashable, Sendable {
    let identity: RepoIdentity
    let pushedAt: Date?
}

struct RepositoryPreference: Equatable, Sendable {
    var isExcluded: Bool
    var isAccessible: Bool

    static let defaults = RepositoryPreference(isExcluded: false, isAccessible: true)
}

struct DiscoveredRepository: Identifiable, Hashable, Sendable {
    let identity: RepoIdentity
    let source: RepositorySource
    let localPath: String?
    let pushedAt: Date?
    let workflows: [WorkflowMetadata]
    var isExcluded: Bool
    var isAccessible: Bool

    var id: String { identity.normalizedKey }
}

enum LocalScanSkipReason: String, Codable, Sendable {
    case githubWithoutWorkflowFiles = "github_without_workflow_files"
    case noWorkflowFiles = "no_workflow_files"
    case nonGitHubOrigin = "non_github_origin"
    case unreadableGitMetadata = "unreadable_git_metadata"
}

struct SkippedLocalRepository: Hashable, Sendable {
    let relativePath: String
    let reason: LocalScanSkipReason
}

struct LocalScanResult: Equatable, Sendable {
    let repositories: [LocalRepository]
    let skippedRepositories: [SkippedLocalRepository]

    static let empty = LocalScanResult(repositories: [], skippedRepositories: [])
}

struct RepoDiscoverySnapshot: Equatable, Sendable {
    let codeRootPath: String?
    let repositories: [DiscoveredRepository]
    let skippedLocalRepositories: [SkippedLocalRepository]
}

enum RepoDiscoveryError: Error, Equatable, Sendable {
    case invalidCodeRoot
    case unreadableCodeRoot
    case invalidRemoteResponse
    case remoteUnauthorized
    case remoteForbidden
    case remoteStatus(Int)
    case remoteTransport
    case persistence(String)

    var userMessage: String {
        switch self {
        case .invalidCodeRoot:
            "Choose a readable folder containing your code repositories."
        case .unreadableCodeRoot:
            "Runbar could not read the selected code folder."
        case .invalidRemoteResponse:
            "GitHub returned an invalid repository list."
        case .remoteUnauthorized:
            "GitHub rejected the saved credential while discovering repositories."
        case .remoteForbidden:
            "GitHub denied repository discovery. Check token repository access and organization approval."
        case let .remoteStatus(status):
            "GitHub returned HTTP \(status) while discovering repositories."
        case .remoteTransport:
            "GitHub repository discovery could not reach the network."
        case let .persistence(message):
            "Runbar could not update its local repository database: \(message)"
        }
    }
}
