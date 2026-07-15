import Foundation

struct GitWatchRepository: Equatable, Sendable {
    let key: String
    let localPath: String
}

struct GitFileEventBatch: Equatable, Sendable {
    let paths: [String]
    let detectedAt: Date
}

struct GitWatcherEvent: Equatable, Sendable {
    let repositoryKey: String
    let signal: GitReferenceSignal
    let referenceStorageBefore: GitReferenceStorage
    let detectedAt: Date
    let pollStartedAt: Date?
    let currentSHA: String?

    var latencyMilliseconds: Int? {
        guard let pollStartedAt else { return nil }
        return max(0, Int((pollStartedAt.timeIntervalSince(detectedAt) * 1_000).rounded()))
    }
}

protocol GitFileEventSourcing: Sendable {
    func events(for paths: [String]) -> AsyncStream<GitFileEventBatch>
}

protocol LocalPushPolling: Sendable {
    func handleLocalPush(repositoryKey: String) async -> Date?
}

protocol GitWatcherRecording: Sendable {
    func updateCurrentSHA(_ sha: String?, repositoryKey: String) async throws
    func recordGitWatcherEvent(_ event: GitWatcherEvent) async throws
}
