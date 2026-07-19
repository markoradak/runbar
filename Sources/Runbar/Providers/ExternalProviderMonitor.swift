import Foundation

actor ExternalProviderMonitor: LocalPushPolling {
    typealias EventHandler = @Sendable (ProviderMonitorSnapshot) async -> Void

    /// How long polls stay fast after a local push. Providers create the
    /// deployment a few seconds *after* the push reaches them, so the
    /// immediate push-triggered refresh usually finds nothing yet; the hot
    /// window keeps polling until the new deployment shows up. The window
    /// closes the moment one does, so it only runs to full length when a push
    /// produces no deployment at all.
    static let hotWindowDuration: TimeInterval = 90
    /// A deployment appears a few seconds after the push, so a flat cadence
    /// misses it by seconds and then waits a whole interval. Tighten instead,
    /// mirroring `PollScheduler.localPushBurstIntervals`. Providers have no
    /// conditional-request equivalent of GitHub's ETag 304s, so these polls
    /// all consume quota — hence three steps rather than a longer ramp.
    static let localPushBurstIntervals: [TimeInterval] = [2, 4, 8]
    /// Cadence inside the hot window once the burst above is spent.
    static let hotInterval: Duration = .seconds(15)
    static let activeInterval: Duration = .seconds(60)
    static let idleInterval: Duration = .seconds(300)

    /// Providers publish very different quota totals — Cloudflare allows about
    /// 1,200 requests per five minutes, Vercel's limits vary per endpoint — so
    /// there is no provider equivalent of GitHub's 500-of-5,000 threshold. Back
    /// off once the remaining quota is small in absolute terms: at our own poll
    /// rate (at most 240/hour/provider) this only trips when something else is
    /// spending the same token.
    static let degradationThreshold = 100
    static let degradedIntervalMultiplier = 4

    private let clients: [ExecutionProvider: any ExternalProviderClient]
    private let store: any ProviderExecutionStoring
    private let now: @Sendable () -> Date
    private var tokens: [ExecutionProvider: String] = [:]
    private var snapshotValue = ProviderMonitorSnapshot.idle
    private var activeCounts: [ExecutionProvider: Int] = [:]
    private var hotWindowUntil: Date?
    /// Remaining post-push burst steps; see `localPushBurstIntervals`.
    private var localPushBurst: [TimeInterval] = []
    /// Execution IDs seen so far, per provider. The post-push window closes
    /// when an ID we have never seen appears; matching on identity rather than
    /// on `createdAt` keeps this immune to clock skew against the provider.
    private var knownExecutionIDs: [ExecutionProvider: Set<Int64>] = [:]
    /// Set when a refresh is requested while one is already in flight. The
    /// push-triggered refresh is the one that matters most, so it must not be
    /// dropped just because a scheduled pass happened to be running.
    private var refreshPending = false
    /// Set from a 429's `Retry-After`. A provider that has asked us to wait is
    /// skipped until it passes — otherwise the loop keeps hitting a provider
    /// that just told us to stop ("never silently keep hammering" — docs/ARCHITECTURE.md, invariant 5).
    private var backoffUntil: [ExecutionProvider: Date] = [:]
    private var loopTask: Task<Void, Never>?
    private var eventHandler: EventHandler?
    /// The interval the loop was last armed with. `currentPollInterval()` only
    /// reports what the *next* poll would use, which differs from what was
    /// actually scheduled once a burst step has been consumed.
    private var lastScheduledInterval: Duration?

    init(
        clients: [any ExternalProviderClient],
        store: any ProviderExecutionStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clients = Dictionary(uniqueKeysWithValues: clients.map { ($0.provider, $0) })
        self.store = store
        self.now = now
    }

    deinit { loopTask?.cancel() }

    func setEventHandler(_ handler: EventHandler?) async {
        eventHandler = handler
        await emitSnapshot()
    }

    func configure(tokens: [ExecutionProvider: String]) async {
        self.tokens = tokens.filter { !$0.value.isEmpty }
        for provider in ExecutionProvider.externalProviders {
            snapshotValue.connections[provider] = self.tokens[provider] == nil
                ? .disconnected
                : .validating
        }
        await emitSnapshot()
        await refreshAll()
        restartLoop()
    }

    @discardableResult
    func connect(provider: ExecutionProvider, token: String) async throws -> ProviderFetchResult {
        guard let client = clients[provider], !token.isEmpty else {
            throw ProviderClientError.authentication
        }
        snapshotValue.connections[provider] = .validating
        await emitSnapshot()
        do {
            let result = try await client.fetch(token: token)
            try await store.saveProviderExecutions(result.executions, provider: provider)
            tokens[provider] = token
            apply(result)
            restartLoop()
            await emitSnapshot()
            return result
        } catch let error as ProviderClientError {
            snapshotValue.connections[provider] = .failed(
                message: error.userMessage,
                hasStoredCredential: tokens[provider] != nil
            )
            await emitSnapshot()
            throw error
        } catch {
            snapshotValue.connections[provider] = .failed(
                message: ProviderClientError.transport.userMessage,
                hasStoredCredential: tokens[provider] != nil
            )
            await emitSnapshot()
            throw ProviderClientError.transport
        }
    }

    func disconnect(provider: ExecutionProvider) async {
        tokens.removeValue(forKey: provider)
        activeCounts.removeValue(forKey: provider)
        snapshotValue.connections[provider] = .disconnected
        snapshotValue.rateLimits.removeValue(forKey: provider)
        snapshotValue.activeExecutionCount = activeCounts.values.reduce(0, +)
        try? await store.deleteProviderExecutions(provider: provider)
        restartLoop()
        await emitSnapshot()
    }

    func refreshAll() async {
        guard !tokens.isEmpty else {
            await emitSnapshot()
            return
        }
        // A refresh is already running. Dropping this one would silently lose
        // the push-triggered refresh whenever a scheduled pass overlapped it,
        // costing a full interval; queue it to run again instead.
        guard !snapshotValue.isRefreshing else {
            refreshPending = true
            await emitSnapshot()
            return
        }
        snapshotValue.isRefreshing = true
        await emitSnapshot()

        repeat {
            refreshPending = false
            await fetchFromProviders()
        } while refreshPending

        snapshotValue.lastSyncAt = now()
        snapshotValue.isRefreshing = false
        updateDegradedFlag()
        restartLoop(consumingBurstStep: true)
        await emitSnapshot()
    }

    private func fetchFromProviders() async {
        for provider in ExecutionProvider.externalProviders {
            guard let token = tokens[provider], let client = clients[provider] else { continue }
            // The provider asked us to wait; leave its last state on screen.
            if let until = backoffUntil[provider], now() < until { continue }
            do {
                let result = try await client.fetch(token: token)
                try await store.saveProviderExecutions(result.executions, provider: provider)
                backoffUntil[provider] = nil
                apply(result)
            } catch let error as ProviderClientError {
                if case let .rateLimited(retryAt) = error, let retryAt {
                    backoffUntil[provider] = retryAt
                }
                snapshotValue.connections[provider] = .failed(
                    message: error.userMessage,
                    hasStoredCredential: true
                )
            } catch {
                snapshotValue.connections[provider] = .failed(
                    message: ProviderClientError.transport.userMessage,
                    hasStoredCredential: true
                )
            }
        }
    }

    func handleWake() async {
        await refreshAll()
    }

    /// Returns an execution's log lines (newest last) for failure display.
    func executionLogLines(
        provider: ExecutionProvider,
        externalID: String,
        projectKey: String
    ) async throws -> [String] {
        guard let token = tokens[provider], let client = clients[provider] else {
            throw ProviderClientError.authentication
        }
        return try await client.logLines(externalID: externalID, projectKey: projectKey, token: token)
    }

    func handleLocalPush(repositoryKey _: String) async -> Date? {
        guard !tokens.isEmpty else { return nil }
        let startedAt = now()
        hotWindowUntil = startedAt.addingTimeInterval(Self.hotWindowDuration)
        localPushBurst = Self.localPushBurstIntervals
        // Awaited rather than detached so the burst's first step is scheduled
        // off a completed refresh, and so `GitWatcher` records a poll that
        // actually ran. `CompositeLocalPushPoller` still runs providers and
        // GitHub concurrently.
        await refreshAll()
        return startedAt
    }

    func snapshot() -> ProviderMonitorSnapshot { snapshotValue }

    /// The interval the poll loop is currently armed with.
    func scheduledInterval() -> Duration? { lastScheduledInterval }

    private func apply(_ result: ProviderFetchResult) {
        snapshotValue.connections[result.provider] = .connected(
            accountLabel: result.accountLabel,
            projectCount: result.projectCount
        )
        snapshotValue.rateLimits[result.provider] = result.rateLimit
        snapshotValue.lastSyncAt = result.fetchedAt
        activeCounts[result.provider] = result.executions.filter { $0.status != "completed" }.count
        snapshotValue.activeExecutionCount = activeCounts.values.reduce(0, +)
        noteExecutions(result)
        updateDegradedFlag()
    }

    /// Records which executions we have seen, and closes the post-push window
    /// as soon as a previously unseen one appears — that is the deployment the
    /// burst was waiting for, so there is nothing left to poll fast for.
    /// Matching on unseen IDs rather than on `activeExecutionCount` matters:
    /// the count is summed across every project, so an unrelated deployment
    /// running elsewhere would otherwise end the burst immediately.
    private func noteExecutions(_ result: ProviderFetchResult) {
        let incoming = Set(result.executions.map(\.syntheticID))
        let seen = knownExecutionIDs[result.provider] ?? []
        knownExecutionIDs[result.provider] = seen.union(incoming)
        guard hotWindowUntil != nil, !incoming.subtracting(seen).isEmpty else { return }
        hotWindowUntil = nil
        localPushBurst = []
    }

    /// Called from every path that changes quota state — `apply` covers connect
    /// and successful refreshes, `refreshAll`'s tail covers the case where every
    /// provider errored and `apply` never ran.
    private func updateDegradedFlag() {
        snapshotValue.isRateLimitDegraded = isRateLimitDegraded
            || backoffUntil.values.contains { now() < $0 }
    }

    /// The interval until the next scheduled refresh: fast inside the
    /// post-push hot window, moderate while executions are active, slow when
    /// everything is idle — then widened if a provider is low on quota, and
    /// finally stretched to cover any outstanding `Retry-After`.
    func currentPollInterval() -> Duration {
        var interval = basePollInterval()
        if isRateLimitDegraded {
            interval *= Self.degradedIntervalMultiplier
        }
        if let soonestRetry = backoffUntil.values.min() {
            let wait = soonestRetry.timeIntervalSince(now())
            if wait > 0 {
                interval = max(interval, .seconds(wait))
            }
        }
        return interval
    }

    private func basePollInterval() -> Duration {
        if let hotWindowUntil, now() < hotWindowUntil {
            guard let nextBurstStep = localPushBurst.first else { return Self.hotInterval }
            return .seconds(nextBurstStep)
        }
        return snapshotValue.activeExecutionCount > 0 ? Self.activeInterval : Self.idleInterval
    }

    /// True while any connected provider reports a small remaining quota.
    /// Mirrors `PollScheduler`'s GitHub-side degradation so a provider running
    /// out of quota widens polling instead of burning what is left.
    private var isRateLimitDegraded: Bool {
        snapshotValue.rateLimits.values.contains { limit in
            guard let remaining = limit.remaining else { return false }
            return remaining < Self.degradationThreshold
        }
    }

    /// `consumingBurstStep` is set by the refresh path only: a burst step is
    /// spent by the poll it schedules, so connect/disconnect restarting the
    /// loop must not eat one.
    private func restartLoop(consumingBurstStep: Bool = false) {
        loopTask?.cancel()
        loopTask = nil
        guard !tokens.isEmpty else { return }
        let interval = currentPollInterval()
        lastScheduledInterval = interval
        if consumingBurstStep, !localPushBurst.isEmpty {
            localPushBurst.removeFirst()
        }
        loopTask = Task { [weak self] in
            do { try await Task.sleep(for: interval) }
            catch { return }
            await self?.refreshAll()
        }
    }

    private func emitSnapshot() async {
        guard let eventHandler else { return }
        await eventHandler(snapshotValue)
    }
}

struct CompositeLocalPushPoller: LocalPushPolling {
    let pollers: [any LocalPushPolling]

    func handleLocalPush(repositoryKey: String) async -> Date? {
        await withTaskGroup(of: Date?.self) { group in
            for poller in pollers {
                group.addTask { await poller.handleLocalPush(repositoryKey: repositoryKey) }
            }
            var earliest: Date?
            for await date in group {
                guard let date else { continue }
                earliest = min(earliest ?? date, date)
            }
            return earliest
        }
    }
}
