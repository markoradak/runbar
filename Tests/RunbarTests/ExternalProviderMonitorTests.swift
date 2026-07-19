import Foundation
import XCTest
@testable import Runbar

final class ExternalProviderMonitorTests: XCTestCase {
    func testConnectPersistsExecutionsAndPublishesConnectedState() async throws {
        let now = Date()
        let execution = ProviderExecution(
            provider: .vercel,
            externalID: "dpl_1",
            repository: RepoIdentity(owner: "owner", name: "site"),
            projectKey: "team/site",
            projectName: "site",
            status: "in_progress",
            conclusion: nil,
            startedAt: now,
            createdAt: now,
            updatedAt: now,
            headBranch: "main",
            headSHA: "abc",
            environment: "Production",
            displayTitle: "Build",
            webURL: "https://vercel.com/build"
        )
        let client = StubExternalProviderClient(
            provider: .vercel,
            result: .success(
                ProviderFetchResult(
                    provider: .vercel,
                    accountLabel: "Studio",
                    executions: [execution],
                    projectCount: 1,
                    rateLimit: ProviderRateLimit(remaining: 900, resetAt: nil),
                    fetchedAt: now
                )
            )
        )
        let store = MemoryProviderExecutionStore()
        let monitor = ExternalProviderMonitor(clients: [client], store: store, now: { now })

        _ = try await monitor.connect(provider: .vercel, token: "token")

        let snapshot = await monitor.snapshot()
        XCTAssertEqual(snapshot.connections[.vercel], .connected(accountLabel: "Studio", projectCount: 1))
        XCTAssertEqual(snapshot.activeExecutionCount, 1)
        XCTAssertEqual(snapshot.lastSyncAt, now)
        let saved = await store.savedExecutions(provider: .vercel)
        XCTAssertEqual(saved, [execution])

        await monitor.refreshAll()
        let refreshedSnapshot = await monitor.snapshot()
        XCTAssertFalse(refreshedSnapshot.isRefreshing)

        await monitor.disconnect(provider: .vercel)
        let disconnectedSnapshot = await monitor.snapshot()
        let deletedProviders = await store.deletedProviders()
        XCTAssertEqual(disconnectedSnapshot.connections[.vercel], .disconnected)
        XCTAssertEqual(deletedProviders, [.vercel])
    }

    func testLocalPushOpensHotPollingWindowUntilItExpires() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000))
        let client = StubExternalProviderClient(
            provider: .vercel,
            result: .success(
                ProviderFetchResult(
                    provider: .vercel,
                    accountLabel: "Studio",
                    executions: [],
                    projectCount: 0,
                    rateLimit: ProviderRateLimit(remaining: 900, resetAt: nil),
                    fetchedAt: clock.now()
                )
            )
        )
        let monitor = ExternalProviderMonitor(
            clients: [client],
            store: MemoryProviderExecutionStore(),
            now: { clock.now() }
        )
        _ = try await monitor.connect(provider: .vercel, token: "token")

        // Idle with nothing active: slow cadence.
        let idleInterval = await monitor.currentPollInterval()
        XCTAssertEqual(idleInterval, ExternalProviderMonitor.idleInterval)

        // A local push opens the hot window even though the provider has not
        // created the deployment yet, and the burst tightens rather than
        // sitting at a flat cadence that could miss the deployment by seconds
        // and then wait a whole interval.
        _ = await monitor.handleLocalPush(repositoryKey: "owner/site")
        var scheduled = await monitor.scheduledInterval()
        XCTAssertEqual(scheduled, .seconds(2))

        for expected in [Duration.seconds(4), .seconds(8), ExternalProviderMonitor.hotInterval] {
            await monitor.refreshAll()
            scheduled = await monitor.scheduledInterval()
            XCTAssertEqual(scheduled, expected)
        }

        // After the window elapses the cadence falls back to idle.
        clock.advance(by: ExternalProviderMonitor.hotWindowDuration + 1)
        let expiredInterval = await monitor.currentPollInterval()
        XCTAssertEqual(expiredInterval, ExternalProviderMonitor.idleInterval)
    }

    /// The burst exists to catch the deployment the push created, so it ends
    /// as soon as one we have not seen before appears.
    func testNewDeploymentClosesThePostPushWindow() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000))
        let deployment = ProviderExecution(
            provider: .vercel,
            externalID: "dpl_new",
            repository: RepoIdentity(owner: "owner", name: "site"),
            projectKey: "team/site",
            projectName: "site",
            status: "in_progress",
            conclusion: nil,
            startedAt: clock.now(),
            createdAt: clock.now(),
            updatedAt: clock.now(),
            headBranch: "main",
            headSHA: "abc",
            environment: "Production",
            displayTitle: "Build",
            webURL: "https://vercel.com/build"
        )
        let client = SequencedExternalProviderClient(
            provider: .vercel,
            results: [
                // Connect, then the push-triggered refresh that is still empty.
                .success(Self.fetchResult(remaining: 900, at: clock.now())),
                .success(Self.fetchResult(remaining: 900, at: clock.now()))
            ],
            fallback: .success(
                ProviderFetchResult(
                    provider: .vercel,
                    accountLabel: "Studio",
                    executions: [deployment],
                    projectCount: 1,
                    rateLimit: ProviderRateLimit(remaining: 900, resetAt: nil),
                    fetchedAt: clock.now()
                )
            )
        )
        let monitor = ExternalProviderMonitor(
            clients: [client],
            store: MemoryProviderExecutionStore(),
            now: { clock.now() }
        )
        try await monitor.connect(provider: .vercel, token: "token")

        _ = await monitor.handleLocalPush(repositoryKey: "owner/site")
        let burstStep = await monitor.scheduledInterval()
        XCTAssertEqual(burstStep, .seconds(2), "Push should start the burst")

        // The deployment now shows up: the window closes and the cadence
        // reverts to the active-execution rate instead of burning the burst.
        await monitor.refreshAll()
        let afterDeployment = await monitor.currentPollInterval()
        XCTAssertEqual(afterDeployment, ExternalProviderMonitor.activeInterval)
    }

    /// A scheduled refresh overlapping a push used to swallow the
    /// push-triggered one, costing a whole interval before the deployment
    /// surfaced. It must be queued and re-run instead.
    func testRefreshRequestedDuringAnInFlightRefreshIsNotDropped() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        // Gate the second fetch so `connect` completes and the refresh under
        // test is the one left in flight.
        let client = GatedExternalProviderClient(
            provider: .vercel,
            result: Self.fetchResult(remaining: 900, at: now),
            gateAtFetch: 2
        )
        let monitor = ExternalProviderMonitor(
            clients: [client],
            store: MemoryProviderExecutionStore(),
            now: { now }
        )
        try await monitor.connect(provider: .vercel, token: "token")

        let inFlight = Task { await monitor.refreshAll() }
        await client.waitUntilGateReached()

        // Arrives mid-refresh — this is the push-triggered case.
        await monitor.refreshAll()

        await client.release()
        await inFlight.value

        let fetches = await client.fetchCount()
        XCTAssertEqual(fetches, 3, "Refresh requested mid-flight was dropped instead of re-run")
    }

    /// A 429 carries `Retry-After`. Honouring it is the whole point: the poll
    /// loop must not keep hitting a provider that just asked us to stop.
    func testRateLimitedProviderIsNotPolledAgainUntilRetryAfterPasses() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = MutableClock(now: start)
        // Deliberately longer than the 300s idle base, so the assertion proves
        // Retry-After stretched the interval rather than the base covering it.
        let retryAt = start.addingTimeInterval(600)
        let client = SequencedExternalProviderClient(
            provider: .vercel,
            results: [
                .success(Self.fetchResult(remaining: 900, at: start)),
                .failure(.rateLimited(retryAt: retryAt))
            ],
            fallback: .success(Self.fetchResult(remaining: 900, at: start))
        )
        let monitor = ExternalProviderMonitor(
            clients: [client],
            store: MemoryProviderExecutionStore(),
            now: { clock.now() }
        )
        try await monitor.connect(provider: .vercel, token: "token")
        let afterConnect = await client.fetchCount()
        XCTAssertEqual(afterConnect, 1)

        // The 429 lands and is recorded.
        await monitor.refreshAll()
        let afterRateLimit = await client.fetchCount()
        XCTAssertEqual(afterRateLimit, 2)
        let degraded = await monitor.snapshot()
        XCTAssertTrue(degraded.isRateLimitDegraded)

        // The next interval covers the Retry-After rather than the 300s idle base.
        let backoffInterval = await monitor.currentPollInterval()
        XCTAssertEqual(backoffInterval, .seconds(600))

        // Any refresh before Retry-After must not touch the provider.
        clock.advance(by: 300)
        await monitor.refreshAll()
        let duringBackoff = await client.fetchCount()
        XCTAssertEqual(duringBackoff, 2, "Polled a provider that asked us to wait")

        // Once it passes, polling resumes and the degraded flag clears.
        clock.advance(by: 301)
        await monitor.refreshAll()
        let afterBackoff = await client.fetchCount()
        XCTAssertEqual(afterBackoff, 3)
        let recovered = await monitor.snapshot()
        XCTAssertFalse(recovered.isRateLimitDegraded)
    }

    func testLowRemainingQuotaWidensThePollInterval() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let client = SequencedExternalProviderClient(
            provider: .vercel,
            results: [],
            fallback: .success(
                Self.fetchResult(remaining: ExternalProviderMonitor.degradationThreshold - 1, at: now)
            )
        )
        let monitor = ExternalProviderMonitor(
            clients: [client],
            store: MemoryProviderExecutionStore(),
            now: { now }
        )
        try await monitor.connect(provider: .vercel, token: "token")

        let interval = await monitor.currentPollInterval()
        XCTAssertEqual(interval, ExternalProviderMonitor.idleInterval * ExternalProviderMonitor.degradedIntervalMultiplier)
        let snapshot = await monitor.snapshot()
        XCTAssertTrue(snapshot.isRateLimitDegraded)
    }

    private static func fetchResult(remaining: Int, at date: Date) -> ProviderFetchResult {
        ProviderFetchResult(
            provider: .vercel,
            accountLabel: "Studio",
            executions: [],
            projectCount: 0,
            rateLimit: ProviderRateLimit(remaining: remaining, resetAt: nil),
            fetchedAt: date
        )
    }

    func testRejectedTokenProducesActionableFailedState() async {
        let client = StubExternalProviderClient(
            provider: .cloudflarePages,
            result: .failure(.authentication)
        )
        let monitor = ExternalProviderMonitor(
            clients: [client],
            store: MemoryProviderExecutionStore()
        )

        do {
            _ = try await monitor.connect(provider: .cloudflarePages, token: "bad")
            XCTFail("Expected authentication failure")
        } catch {
            let snapshot = await monitor.snapshot()
            XCTAssertEqual(
                snapshot.connections[.cloudflarePages],
                .failed(message: ProviderClientError.authentication.userMessage, hasStoredCredential: false)
            )
        }
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) {
        current = now
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

private actor StubExternalProviderClient: ExternalProviderClient {
    nonisolated let provider: ExecutionProvider
    private let result: Result<ProviderFetchResult, ProviderClientError>

    init(provider: ExecutionProvider, result: Result<ProviderFetchResult, ProviderClientError>) {
        self.provider = provider
        self.result = result
    }

    func fetch(token: String) async throws -> ProviderFetchResult {
        try result.get()
    }


    func logLines(externalID _: String, projectKey _: String, token _: String) async throws -> [String] {
        []
    }
}

/// Yields `results` in order, then `fallback` forever, and counts fetches so a
/// test can assert that a provider was *not* contacted.
private actor SequencedExternalProviderClient: ExternalProviderClient {
    nonisolated let provider: ExecutionProvider
    private var results: [Result<ProviderFetchResult, ProviderClientError>]
    private let fallback: Result<ProviderFetchResult, ProviderClientError>
    private var fetches = 0

    init(
        provider: ExecutionProvider,
        results: [Result<ProviderFetchResult, ProviderClientError>],
        fallback: Result<ProviderFetchResult, ProviderClientError>
    ) {
        self.provider = provider
        self.results = results
        self.fallback = fallback
    }

    func fetch(token _: String) async throws -> ProviderFetchResult {
        fetches += 1
        guard !results.isEmpty else { return try fallback.get() }
        return try results.removeFirst().get()
    }

    func logLines(externalID _: String, projectKey _: String, token _: String) async throws -> [String] {
        []
    }

    func fetchCount() -> Int { fetches }
}

/// Blocks the `gateAtFetch`-th fetch until `release()`, so a test can hold a
/// refresh in flight and observe what happens to one requested meanwhile.
private actor GatedExternalProviderClient: ExternalProviderClient {
    nonisolated let provider: ExecutionProvider
    private let result: ProviderFetchResult
    private let gateAtFetch: Int
    private var fetches = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var gateReached: CheckedContinuation<Void, Never>?
    private var hasReachedGate = false

    init(provider: ExecutionProvider, result: ProviderFetchResult, gateAtFetch: Int) {
        self.provider = provider
        self.result = result
        self.gateAtFetch = gateAtFetch
    }

    func fetch(token _: String) async throws -> ProviderFetchResult {
        fetches += 1
        if fetches == gateAtFetch {
            hasReachedGate = true
            gateReached?.resume()
            gateReached = nil
            await withCheckedContinuation { gate = $0 }
        }
        return result
    }

    func logLines(externalID _: String, projectKey _: String, token _: String) async throws -> [String] {
        []
    }

    func waitUntilGateReached() async {
        guard !hasReachedGate else { return }
        await withCheckedContinuation { gateReached = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func fetchCount() -> Int { fetches }
}

private actor MemoryProviderExecutionStore: ProviderExecutionStoring {
    private var saved: [ExecutionProvider: [ProviderExecution]] = [:]
    private var deleted: [ExecutionProvider] = []

    func saveProviderExecutions(
        _ executions: [ProviderExecution],
        provider: ExecutionProvider
    ) async throws {
        saved[provider] = executions
    }

    func deleteProviderExecutions(provider: ExecutionProvider) async throws {
        saved.removeValue(forKey: provider)
        deleted.append(provider)
    }

    func savedExecutions(provider: ExecutionProvider) -> [ProviderExecution] {
        saved[provider] ?? []
    }

    func deletedProviders() -> [ExecutionProvider] { deleted }
}
