import XCTest
@testable import Runbar

final class PollSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testReconciliationAssignsExactlyOneTierAndIndependentJitterPerRepository() async {
        let clock = ManualPollClock(now: now)
        let poller = ScriptedRunPoller(steps: [
            "a-hot": [.success(result(runs: [run(id: 1, status: "in_progress")]))],
            "b-warm": [.success(result(runs: [run(id: 2, status: "completed", updatedAt: now.addingTimeInterval(-30 * 60))]))],
            "c-cold": [.success(result(runs: []))]
        ])
        let random = DeterministicPollRandomSource(values: [0, 0.5, 1])
        let recorder = MemoryPollRecorder()
        let scheduler = makeScheduler(poller: poller, clock: clock, random: random, recorder: recorder)
        await scheduler.updateRepositories([
            repository("a-hot", pushedAt: now.addingTimeInterval(-2 * 60 * 60)),
            repository("b-warm", pushedAt: now.addingTimeInterval(-2 * 60 * 60)),
            repository("c-cold", pushedAt: now.addingTimeInterval(-2 * 60 * 60))
        ])

        await scheduler.reconcile(trigger: .launch)

        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.repositories.count, 3)
        XCTAssertEqual(Set(snapshot.repositories.map(\.repositoryKey)).count, 3)
        XCTAssertEqual(snapshot.tierCounts[.hot], 1)
        XCTAssertEqual(snapshot.tierCounts[.warm], 1)
        XCTAssertEqual(snapshot.tierCounts[.cold], 1)
        XCTAssertEqual(interval(for: "a-hot", in: snapshot), 6.8, accuracy: 0.001)
        XCTAssertEqual(interval(for: "b-warm", in: snapshot), 60, accuracy: 0.001)
        XCTAssertEqual(interval(for: "c-cold", in: snapshot), 690, accuracy: 0.001)

        let events = await recorder.events()
        XCTAssertEqual(events.map(\.trigger), [.launch, .launch, .launch])
        XCTAssertEqual(events.map(\.jitterFactor), [0.85, 1, 1.15])
    }

    func testActiveRunCompletionTransitionsHotToWarmAtNextDuePoll() async {
        let clock = ManualPollClock(now: now)
        let poller = ScriptedRunPoller(steps: [
            "owner/repo": [
                .success(result(runs: [run(id: 1, status: "queued")])),
                .success(result(
                    runs: [run(id: 1, status: "completed", updatedAt: now.addingTimeInterval(8))],
                    fetchedAt: now.addingTimeInterval(8)
                ))
            ]
        ])
        let scheduler = makeScheduler(
            poller: poller,
            clock: clock,
            random: DeterministicPollRandomSource(values: [0.5, 0.5])
        )
        await scheduler.updateRepositories([
            repository("owner/repo", pushedAt: now.addingTimeInterval(-2 * 60 * 60))
        ])
        await scheduler.reconcile(trigger: .launch)
        let initialSnapshot = await scheduler.snapshot()
        XCTAssertEqual(initialSnapshot.repositories.first?.tier, .hot)

        await clock.set(now.addingTimeInterval(8))
        await scheduler.pollDueRepositories()

        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.repositories.first?.tier, .warm)
        XCTAssertEqual(interval(for: "owner/repo", in: snapshot, relativeTo: now.addingTimeInterval(8)), 60)
        let callCount = await poller.callCount(repositoryKey: "owner/repo")
        XCTAssertEqual(callCount, 2)
    }

    func testJitterClampsToPlusOrMinusFifteenPercentAndAvoidsSharedFireDate() async {
        let clock = ManualPollClock(now: now)
        let poller = ScriptedRunPoller(steps: [
            "a": [.success(result(runs: []))],
            "b": [.success(result(runs: []))],
            "c": [.success(result(runs: []))]
        ])
        let scheduler = makeScheduler(
            poller: poller,
            clock: clock,
            random: DeterministicPollRandomSource(values: [-3, 0.5, 7])
        )
        await scheduler.updateRepositories([
            repository("a", pushedAt: nil),
            repository("b", pushedAt: nil),
            repository("c", pushedAt: nil)
        ])

        await scheduler.reconcile(trigger: .launch)

        let dates = (await scheduler.snapshot()).repositories.map(\.nextPollAt)
        XCTAssertEqual(Set(dates).count, 3)
        XCTAssertEqual(dates.map { $0.timeIntervalSince(now) }.sorted(), [510, 600, 690])
    }

    func testRateLimitBelowFiveHundredWidensAllIntervalsAndFiveHundredRecovers() async {
        let clock = ManualPollClock(now: now)
        let poller = ScriptedRunPoller(steps: [
            "owner/repo": [
                .success(result(runs: [], remaining: 499)),
                .success(result(runs: [], remaining: 500, fetchedAt: now.addingTimeInterval(2_400)))
            ]
        ])
        let recorder = MemoryPollRecorder()
        let scheduler = makeScheduler(
            poller: poller,
            clock: clock,
            random: DeterministicPollRandomSource(values: [0.5, 0.5]),
            recorder: recorder
        )
        await scheduler.updateRepositories([repository("owner/repo", pushedAt: nil)])

        await scheduler.reconcile(trigger: .launch)
        var snapshot = await scheduler.snapshot()
        XCTAssertTrue(snapshot.isRateLimitDegraded)
        XCTAssertEqual(interval(for: "owner/repo", in: snapshot), 2_400)

        await clock.set(now.addingTimeInterval(2_400))
        await scheduler.pollDueRepositories()
        snapshot = await scheduler.snapshot()
        XCTAssertFalse(snapshot.isRateLimitDegraded)
        XCTAssertEqual(interval(for: "owner/repo", in: snapshot, relativeTo: now.addingTimeInterval(2_400)), 600)

        let events = await recorder.events()
        XCTAssertEqual(events.map(\.isRateLimitDegraded), [true, false])
    }

    func testStartAndWakePerformFullReconciliationAndRecordOneSession() async {
        let clock = ManualPollClock(now: now)
        let poller = ScriptedRunPoller(steps: [
            "a": [.success(result(runs: [])), .success(result(runs: []))],
            "b": [.success(result(runs: [])), .success(result(runs: []))]
        ])
        let recorder = MemoryPollRecorder()
        let scheduler = makeScheduler(
            poller: poller,
            clock: clock,
            random: DeterministicPollRandomSource(values: Array(repeating: 0.5, count: 4)),
            recorder: recorder
        )

        await scheduler.start(repositories: [repository("a", pushedAt: nil), repository("b", pushedAt: nil)])
        await scheduler.handleWake()
        await scheduler.stop()

        let aCallCount = await poller.callCount(repositoryKey: "a")
        let bCallCount = await poller.callCount(repositoryKey: "b")
        let triggers = await recorder.events().map(\.trigger)
        let begunCounts = await recorder.begunRepositoryCounts()
        let endedCount = await recorder.endedSessionCount()
        XCTAssertEqual(aCallCount, 2)
        XCTAssertEqual(bCallCount, 2)
        XCTAssertEqual(triggers, [.launch, .launch, .wake, .wake])
        XCTAssertEqual(begunCounts, [2])
        XCTAssertEqual(endedCount, 1)
    }

    func testAccessDenialRemovesRepositoryAndPreventsFuturePolls() async {
        let poller = ScriptedRunPoller(steps: [
            "owner/private": [.failure(.accessDenied(repositoryKey: "owner/private", firstNotice: true))]
        ])
        let scheduler = makeScheduler(
            poller: poller,
            clock: ManualPollClock(now: now),
            random: DeterministicPollRandomSource(values: [])
        )
        await scheduler.updateRepositories([repository("owner/private", pushedAt: nil)])

        await scheduler.reconcile(trigger: .launch)
        await scheduler.reconcile(trigger: .wake)

        let snapshot = await scheduler.snapshot()
        let callCount = await poller.callCount(repositoryKey: "owner/private")
        XCTAssertTrue(snapshot.repositories.isEmpty)
        XCTAssertEqual(callCount, 1)
    }

    func testMissingCredentialPausesWithoutMakingARequest() async {
        let poller = ScriptedRunPoller(steps: [:])
        let scheduler = PollScheduler(
            poller: poller,
            clock: ManualPollClock(now: now),
            randomSource: DeterministicPollRandomSource(values: []),
            credentialProvider: FixedPollCredentialProvider(token: nil)
        )
        await scheduler.updateRepositories([repository("owner/repo", pushedAt: nil)])

        await scheduler.reconcile(trigger: .launch)

        let snapshot = await scheduler.snapshot()
        XCTAssertTrue(snapshot.hasAuthenticationFailure)
        XCTAssertFalse(snapshot.isRunning)
        let totalCallCount = await poller.totalCallCount()
        XCTAssertEqual(totalCallCount, 0)
    }

    private func makeScheduler(
        poller: ScriptedRunPoller,
        clock: ManualPollClock,
        random: DeterministicPollRandomSource,
        recorder: MemoryPollRecorder? = nil
    ) -> PollScheduler {
        PollScheduler(
            poller: poller,
            clock: clock,
            randomSource: random,
            credentialProvider: FixedPollCredentialProvider(token: "test-marker"),
            recorder: recorder
        )
    }

    private func repository(_ key: String, pushedAt: Date?) -> PollRepository {
        let parts = key.split(separator: "/")
        let owner = parts.count == 2 ? String(parts[0]) : "owner"
        let name = parts.count == 2 ? String(parts[1]) : key
        return PollRepository(key: key, identity: RepoIdentity(owner: owner, name: name), pushedAt: pushedAt)
    }

    private func run(
        id: Int64,
        status: String,
        updatedAt: Date? = nil
    ) -> WorkflowRun {
        WorkflowRun(
            id: id,
            repositoryKey: "owner/repo",
            workflowID: 10,
            workflowName: "CI",
            status: status,
            conclusion: status == "completed" ? "success" : nil,
            runStartedAt: now.addingTimeInterval(-60),
            createdAt: now.addingTimeInterval(-90),
            updatedAt: updatedAt ?? now,
            headBranch: "main",
            headSHA: "abc123",
            event: "push",
            displayTitle: "CI",
            htmlURL: "https://example.invalid/run/\(id)",
            runAttempt: 1,
            actorLogin: "octocat",
            triggeringActorLogin: "octocat"
        )
    }

    private func result(
        runs: [WorkflowRun],
        remaining: Int = 4_999,
        fetchedAt: Date? = nil
    ) -> RepositoryPollResult {
        RepositoryPollResult(
            runs: runs,
            statusCode: 304,
            cacheOutcome: .revalidated304,
            rateLimit: GitHubRateLimit(remaining: remaining, resetAt: now.addingTimeInterval(3_600)),
            fetchedAt: fetchedAt ?? now
        )
    }

    private func interval(
        for key: String,
        in snapshot: PollSchedulerSnapshot,
        relativeTo date: Date? = nil
    ) -> TimeInterval {
        snapshot.repositories.first(where: { $0.repositoryKey == key })!.nextPollAt
            .timeIntervalSince(date ?? now)
    }
}

private actor ManualPollClock: PollSchedulerClock {
    private var current: Date

    init(now: Date) {
        current = now
    }

    func now() async -> Date {
        current
    }

    func set(_ date: Date) {
        current = date
    }

    func sleep(until _: Date) async throws {
        try await Task.sleep(for: .seconds(86_400))
    }
}

private actor DeterministicPollRandomSource: PollRandomSource {
    private var values: [Double]

    init(values: [Double]) {
        self.values = values
    }

    func nextUnitInterval() async -> Double {
        values.isEmpty ? 0.5 : values.removeFirst()
    }
}

private struct FixedPollCredentialProvider: PollCredentialProviding {
    let token: String?

    func readCredential() async throws -> String? {
        token
    }
}

private actor ScriptedRunPoller: RunPolling {
    enum Step: Sendable {
        case success(RepositoryPollResult)
        case failure(GitHubClientError)
    }

    private var steps: [String: [Step]]
    private var calls: [String] = []

    init(steps: [String: [Step]]) {
        self.steps = steps
    }

    func poll(repository: PollRepository, token _: String) async throws -> RepositoryPollResult {
        calls.append(repository.key)
        guard var repositorySteps = steps[repository.key], !repositorySteps.isEmpty else {
            throw GitHubClientError.transport
        }
        let step = repositorySteps.removeFirst()
        steps[repository.key] = repositorySteps
        switch step {
        case let .success(result): return result
        case let .failure(error): throw error
        }
    }

    func callCount(repositoryKey: String) -> Int {
        calls.filter { $0 == repositoryKey }.count
    }

    func totalCallCount() -> Int {
        calls.count
    }
}

private actor MemoryPollRecorder: PollSchedulerRecording {
    private var recordedEvents: [PollSchedulerEvent] = []
    private var begunCounts: [Int] = []
    private var endedCount = 0

    func beginSchedulerSession(startedAt _: Date, repositoryCount: Int) async throws -> Int64 {
        begunCounts.append(repositoryCount)
        return Int64(begunCounts.count)
    }

    func updateSchedulerSession(_: Int64, repositoryCount _: Int) async throws {}

    func recordSchedulerEvent(_ event: PollSchedulerEvent, sessionID _: Int64?) async throws {
        recordedEvents.append(event)
    }

    func endSchedulerSession(_: Int64, endedAt _: Date) async throws {
        endedCount += 1
    }

    func events() -> [PollSchedulerEvent] {
        recordedEvents
    }

    func begunRepositoryCounts() -> [Int] {
        begunCounts
    }

    func endedSessionCount() -> Int {
        endedCount
    }
}
