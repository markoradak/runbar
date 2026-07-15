import Foundation
import XCTest
@testable import Runbar

final class PollSchedulerConcurrentLocalPushTests: XCTestCase {
    func testLocalPushStartsItsOwnPollWhileAnOlderPollIsAwaitingGitHub() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let poller = BlockingLocalPushRunPoller(now: now)
        let recorder = ConcurrentLocalPushRecorder()
        let scheduler = PollScheduler(
            poller: poller,
            clock: ConcurrentLocalPushClock(now: now),
            randomSource: ConcurrentLocalPushRandomSource(),
            credentialProvider: ConcurrentLocalPushCredentialProvider(),
            recorder: recorder
        )
        let repository = PollRepository(
            key: "owner/repo",
            identity: RepoIdentity(owner: "owner", name: "repo"),
            pushedAt: now.addingTimeInterval(-7_200)
        )
        await scheduler.start(repositories: [repository])

        let olderPoll = Task {
            await scheduler.pollImmediately(repositoryKey: repository.key, trigger: .manual)
        }
        await poller.waitUntilOlderPollIsBlocked()

        let pushPollStartedAt = await scheduler.handleLocalPush(repositoryKey: repository.key)
        let callsWhileOlderPollIsBlocked = await poller.callCount()
        let eventsWhileOlderPollIsBlocked = await recorder.events()

        XCTAssertEqual(pushPollStartedAt, now)
        XCTAssertEqual(callsWhileOlderPollIsBlocked, 3)
        XCTAssertEqual(eventsWhileOlderPollIsBlocked.filter { $0.trigger == .localPush }.count, 1)
        XCTAssertEqual(
            eventsWhileOlderPollIsBlocked.first(where: { $0.trigger == .localPush })?.tierBefore,
            .hot
        )

        await poller.releaseOlderPoll()
        await olderPoll.value
    }
}

private actor BlockingLocalPushRunPoller: RunPolling {
    private let now: Date
    private var calls = 0
    private var olderPollIsBlocked = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(now: Date) {
        self.now = now
    }

    func poll(repository _: PollRepository, token _: String) async throws -> RepositoryPollResult {
        calls += 1
        if calls == 2 {
            olderPollIsBlocked = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        return RepositoryPollResult(
            runs: [],
            statusCode: 304,
            cacheOutcome: .revalidated304,
            rateLimit: GitHubRateLimit(remaining: 4_999, resetAt: now.addingTimeInterval(3_600)),
            fetchedAt: now
        )
    }

    func waitUntilOlderPollIsBlocked() async {
        if olderPollIsBlocked { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseOlderPoll() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func callCount() -> Int { calls }
}

private actor ConcurrentLocalPushClock: PollSchedulerClock {
    let current: Date

    init(now: Date) {
        current = now
    }

    func now() async -> Date { current }

    func sleep(until _: Date) async throws {
        try await Task.sleep(for: .seconds(86_400))
    }
}

private struct ConcurrentLocalPushRandomSource: PollRandomSource {
    func nextUnitInterval() async -> Double { 0.5 }
}

private struct ConcurrentLocalPushCredentialProvider: PollCredentialProviding {
    func readCredential() async throws -> String? { "test-marker" }
}

private actor ConcurrentLocalPushRecorder: PollSchedulerRecording {
    private var recordedEvents: [PollSchedulerEvent] = []

    func beginSchedulerSession(startedAt _: Date, repositoryCount _: Int) async throws -> Int64 { 1 }
    func updateSchedulerSession(_: Int64, repositoryCount _: Int) async throws {}
    func endSchedulerSession(_: Int64, endedAt _: Date) async throws {}

    func recordSchedulerEvent(_ event: PollSchedulerEvent, sessionID _: Int64?) async throws {
        recordedEvents.append(event)
    }

    func events() -> [PollSchedulerEvent] { recordedEvents }
}
