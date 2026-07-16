import Foundation

actor ExternalProviderMonitor: LocalPushPolling {
    typealias EventHandler = @Sendable (ProviderMonitorSnapshot) async -> Void

    /// How long polls stay fast after a local push. Providers create the
    /// deployment a few seconds *after* the push reaches them, so the
    /// immediate push-triggered refresh usually finds nothing yet; the hot
    /// window keeps polling until the new deployment shows up.
    static let hotWindowDuration: TimeInterval = 180
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
    /// Set from a 429's `Retry-After`. A provider that has asked us to wait is
    /// skipped until it passes — otherwise the loop keeps hitting a provider
    /// that just told us to stop ("never silently keep hammering" — docs/ARCHITECTURE.md, invariant 5).
    private var backoffUntil: [ExecutionProvider: Date] = [:]
    private var loopTask: Task<Void, Never>?
    private var eventHandler: EventHandler?

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
        for provider in [ExecutionProvider.vercel, .cloudflarePages] {
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
        guard !snapshotValue.isRefreshing, !tokens.isEmpty else {
            await emitSnapshot()
            return
        }
        snapshotValue.isRefreshing = true
        await emitSnapshot()

        for provider in [ExecutionProvider.vercel, .cloudflarePages] {
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
        snapshotValue.lastSyncAt = now()
        snapshotValue.isRefreshing = false
        updateDegradedFlag()
        restartLoop()
        await emitSnapshot()
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
        Task { [weak self] in await self?.refreshAll() }
        return startedAt
    }

    func snapshot() -> ProviderMonitorSnapshot { snapshotValue }

    private func apply(_ result: ProviderFetchResult) {
        snapshotValue.connections[result.provider] = .connected(
            accountLabel: result.accountLabel,
            projectCount: result.projectCount
        )
        snapshotValue.rateLimits[result.provider] = result.rateLimit
        snapshotValue.lastSyncAt = result.fetchedAt
        activeCounts[result.provider] = result.executions.filter { $0.status != "completed" }.count
        snapshotValue.activeExecutionCount = activeCounts.values.reduce(0, +)
        updateDegradedFlag()
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
            return Self.hotInterval
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

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = nil
        guard !tokens.isEmpty else { return }
        let interval = currentPollInterval()
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
