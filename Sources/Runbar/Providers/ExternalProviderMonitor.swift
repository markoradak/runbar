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

    private let clients: [ExecutionProvider: any ExternalProviderClient]
    private let store: any ProviderExecutionStoring
    private let now: @Sendable () -> Date
    private var tokens: [ExecutionProvider: String] = [:]
    private var snapshotValue = ProviderMonitorSnapshot.idle
    private var activeCounts: [ExecutionProvider: Int] = [:]
    private var hotWindowUntil: Date?
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
            do {
                let result = try await client.fetch(token: token)
                try await store.saveProviderExecutions(result.executions, provider: provider)
                apply(result)
            } catch let error as ProviderClientError {
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
        restartLoop()
        await emitSnapshot()
    }

    func handleWake() async {
        await refreshAll()
    }

    /// Cancels a running execution at its provider, then refreshes so the
    /// canceled state shows up promptly.
    func cancelExecution(provider: ExecutionProvider, externalID: String) async throws {
        guard let token = tokens[provider], let client = clients[provider] else {
            throw ProviderClientError.authentication
        }
        try await client.cancel(externalID: externalID, token: token)
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
    }

    /// The interval until the next scheduled refresh: fast inside the
    /// post-push hot window, moderate while executions are active, slow when
    /// everything is idle.
    func currentPollInterval() -> Duration {
        if let hotWindowUntil, now() < hotWindowUntil {
            return Self.hotInterval
        }
        return snapshotValue.activeExecutionCount > 0 ? Self.activeInterval : Self.idleInterval
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
