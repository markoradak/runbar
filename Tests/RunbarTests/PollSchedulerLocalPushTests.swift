import Foundation
import XCTest
@testable import Runbar

final class PollSchedulerLocalPushTests: XCTestCase {
    func testLocalPushPromotesHotAndDispatchesExactlyOneConditionalPoll() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = LocalPushClock(now: now)
        let poller = LocalPushRunPoller(now: now)
        let recorder = LocalPushPollRecorder()
        let scheduler = PollScheduler(
            poller: poller,
            clock: clock,
            randomSource: LocalPushRandomSource(),
            credentialProvider: LocalPushCredentialProvider(),
            recorder: recorder
        )
        let repository = PollRepository(
            key: "owner/repo",
            identity: RepoIdentity(owner: "owner", name: "repo"),
            pushedAt: now.addingTimeInterval(-7_200)
        )
        await scheduler.start(repositories: [repository])

        let pollStartedAt = await scheduler.handleLocalPush(repositoryKey: "owner/repo")

        let calls = await poller.callCount()
        let events = await recorder.events()
        XCTAssertEqual(pollStartedAt, now)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(events.map(\.trigger), [.launch, .localPush])
        XCTAssertEqual(events.last?.tierBefore, .hot)
    }
}

private actor LocalPushClock: PollSchedulerClock {
    let current: Date

    init(now: Date) {
        current = now
    }

    func now() async -> Date { current }

    func sleep(until _: Date) async throws {
        try await Task.sleep(for: .seconds(86_400))
    }
}

private struct LocalPushRandomSource: PollRandomSource {
    func nextUnitInterval() async -> Double { 0.5 }
}

private struct LocalPushCredentialProvider: PollCredentialProviding {
    func readCredential() async throws -> String? { "test-marker" }
}

private actor LocalPushRunPoller: RunPolling {
    private let now: Date
    private var calls = 0

    init(now: Date) {
        self.now = now
    }

    func poll(repository _: PollRepository, token _: String) async throws -> RepositoryPollResult {
        calls += 1
        return RepositoryPollResult(
            runs: [],
            statusCode: 304,
            cacheOutcome: .revalidated304,
            rateLimit: GitHubRateLimit(remaining: 4_999, resetAt: now.addingTimeInterval(3_600)),
            fetchedAt: now
        )
    }

    func callCount() -> Int { calls }
}

private actor LocalPushPollRecorder: PollSchedulerRecording {
    private var recordedEvents: [PollSchedulerEvent] = []

    func beginSchedulerSession(startedAt _: Date, repositoryCount _: Int) async throws -> Int64 { 1 }
    func updateSchedulerSession(_: Int64, repositoryCount _: Int) async throws {}
    func endSchedulerSession(_: Int64, endedAt _: Date) async throws {}

    func recordSchedulerEvent(_ event: PollSchedulerEvent, sessionID _: Int64?) async throws {
        recordedEvents.append(event)
    }

    func events() -> [PollSchedulerEvent] { recordedEvents }
}
