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
        // created the deployment yet.
        _ = await monitor.handleLocalPush(repositoryKey: "owner/site")
        let hotInterval = await monitor.currentPollInterval()
        XCTAssertEqual(hotInterval, ExternalProviderMonitor.hotInterval)

        // After the window elapses the cadence falls back to idle.
        clock.advance(by: ExternalProviderMonitor.hotWindowDuration + 1)
        let expiredInterval = await monitor.currentPollInterval()
        XCTAssertEqual(expiredInterval, ExternalProviderMonitor.idleInterval)
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
