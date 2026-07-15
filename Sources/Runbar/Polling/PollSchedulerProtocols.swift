import Foundation

protocol RunPolling: Sendable {
    func poll(repository: PollRepository, token: String) async throws -> RepositoryPollResult
}

protocol PollSchedulerClock: Sendable {
    func now() async -> Date
    func sleep(until date: Date) async throws
}

protocol PollRandomSource: Sendable {
    func nextUnitInterval() async -> Double
}

protocol PollCredentialProviding: Sendable {
    func readCredential() async throws -> String?
}

protocol PollSchedulerRecording: Sendable {
    func beginSchedulerSession(startedAt: Date, repositoryCount: Int) async throws -> Int64
    func updateSchedulerSession(_ sessionID: Int64, repositoryCount: Int) async throws
    func recordSchedulerEvent(_ event: PollSchedulerEvent, sessionID: Int64?) async throws
    func endSchedulerSession(_ sessionID: Int64, endedAt: Date) async throws
}

struct SystemPollSchedulerClock: PollSchedulerClock {
    func now() async -> Date {
        Date()
    }

    func sleep(until date: Date) async throws {
        let delay = max(0, date.timeIntervalSinceNow)
        try await Task.sleep(for: .milliseconds(Int64(delay * 1_000)))
    }
}

struct SystemPollRandomSource: PollRandomSource {
    func nextUnitInterval() async -> Double {
        Double.random(in: 0...1)
    }
}

struct KeychainPollCredentialProvider: PollCredentialProviding, @unchecked Sendable {
    private let credentialStore: any CredentialStore

    init(credentialStore: any CredentialStore) {
        self.credentialStore = credentialStore
    }

    func readCredential() async throws -> String? {
        try credentialStore.readToken()
    }
}
