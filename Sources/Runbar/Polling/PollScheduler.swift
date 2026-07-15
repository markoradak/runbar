import Foundation

actor PollScheduler {
    typealias EventHandler = @Sendable (PollSchedulerSnapshot) async -> Void

    private struct RepositoryState: Sendable {
        var repository: PollRepository
        var tier: PollingTier
        var nextPollAt: Date
        var lastPollAt: Date?
        var hasActiveRun: Bool
        var latestCompletionAt: Date?
    }

    private static let warmWindow: TimeInterval = 60 * 60
    private static let jitterRange = 0.15
    private static let degradedIntervalMultiplier = 4.0
    private static let degradationThreshold = 500

    private let poller: any RunPolling
    private let clock: any PollSchedulerClock
    private let randomSource: any PollRandomSource
    private let credentialProvider: any PollCredentialProviding
    private let recorder: (any PollSchedulerRecording)?

    private var repositoryStates: [String: RepositoryState] = [:]
    private var inFlightRepositoryKeys: Set<String> = []
    private var loopTask: Task<Void, Never>?
    private var eventHandler: EventHandler?
    private var sessionID: Int64?
    private var sessionStartedAt: Date?
    private var sessionRepositoryCount = 0
    private var isRunning = false
    private var isRateLimitDegraded = false
    private var hasAuthenticationFailure = false
    private var latestRateLimit = GitHubRateLimit(remaining: nil, resetAt: nil)
    private var lastSyncAt: Date?
    private var totalPollAttempts = 0
    private var quotaConsumingRequests = 0
    private var observedActiveRun = false

    init(
        poller: any RunPolling,
        clock: any PollSchedulerClock = SystemPollSchedulerClock(),
        randomSource: any PollRandomSource = SystemPollRandomSource(),
        credentialProvider: any PollCredentialProviding,
        recorder: (any PollSchedulerRecording)? = nil
    ) {
        self.poller = poller
        self.clock = clock
        self.randomSource = randomSource
        self.credentialProvider = credentialProvider
        self.recorder = recorder
    }

    deinit {
        loopTask?.cancel()
    }

    func setEventHandler(_ handler: EventHandler?) async {
        eventHandler = handler
        await emitSnapshot()
    }

    func start(repositories: [PollRepository]) async {
        await updateRepositories(repositories)
        guard !isRunning else { return }

        isRunning = true
        hasAuthenticationFailure = false
        totalPollAttempts = 0
        quotaConsumingRequests = 0
        observedActiveRun = false
        let startedAt = await clock.now()
        sessionStartedAt = startedAt
        sessionRepositoryCount = repositoryStates.count
        if let recorder {
            sessionID = try? await recorder.beginSchedulerSession(
                startedAt: startedAt,
                repositoryCount: repositoryStates.count
            )
        }

        await reconcile(trigger: .launch)
        if isRunning {
            restartLoop()
        }
        await emitSnapshot()
    }

    func stop() async {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        if let sessionID, let recorder {
            try? await recorder.endSchedulerSession(sessionID, endedAt: await clock.now())
        }
        sessionID = nil
        sessionStartedAt = nil
        await emitSnapshot()
    }

    func updateRepositories(_ repositories: [PollRepository]) async {
        let now = await clock.now()
        let incoming = Dictionary(uniqueKeysWithValues: repositories.map { ($0.key, $0) })
        repositoryStates = incoming.reduce(into: [:]) { result, pair in
            let (key, repository) = pair
            if var existing = repositoryStates[key] {
                existing.repository = repository
                result[key] = existing
            } else {
                result[key] = RepositoryState(
                    repository: repository,
                    tier: Self.initialTier(repository: repository, now: now),
                    nextPollAt: now,
                    lastPollAt: nil,
                    hasActiveRun: false,
                    latestCompletionAt: nil
                )
            }
        }
        inFlightRepositoryKeys.formIntersection(incoming.keys)
        sessionRepositoryCount = repositoryStates.count
        if let sessionID, let recorder {
            try? await recorder.updateSchedulerSession(sessionID, repositoryCount: repositoryStates.count)
        }
        if isRunning {
            restartLoop()
        }
        await emitSnapshot()
    }

    func handleWake() async {
        guard isRunning else { return }
        loopTask?.cancel()
        loopTask = nil
        await reconcile(trigger: .wake)
        if isRunning {
            restartLoop()
        }
    }

    func reconcile(trigger: PollTrigger) async {
        let keys = repositoryStates.keys.sorted()
        for key in keys where !Task.isCancelled {
            await pollRepository(key: key, trigger: trigger)
        }
    }

    func pollDueRepositories() async {
        let now = await clock.now()
        let dueKeys = repositoryStates
            .filter { $0.value.nextPollAt <= now }
            .sorted {
                if $0.value.nextPollAt == $1.value.nextPollAt { return $0.key < $1.key }
                return $0.value.nextPollAt < $1.value.nextPollAt
            }
            .map(\.key)
        for key in dueKeys where !Task.isCancelled {
            await pollRepository(key: key, trigger: .scheduled)
        }
    }

    func pollImmediately(repositoryKey: String, trigger: PollTrigger = .manual) async {
        await pollRepository(key: repositoryKey, trigger: trigger)
        if isRunning {
            restartLoop()
        }
    }

    func snapshot() -> PollSchedulerSnapshot {
        makeSnapshot()
    }

    private func runLoop() async {
        while !Task.isCancelled && isRunning && !hasAuthenticationFailure {
            guard let nextPollAt = repositoryStates.values.map(\.nextPollAt).min() else { return }
            do {
                try await clock.sleep(until: nextPollAt)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await pollDueRepositories()
        }
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = nil
        guard isRunning, !hasAuthenticationFailure, !repositoryStates.isEmpty else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func pollRepository(key: String, trigger: PollTrigger) async {
        guard var state = repositoryStates[key], !inFlightRepositoryKeys.contains(key) else { return }
        inFlightRepositoryKeys.insert(key)
        defer { inFlightRepositoryKeys.remove(key) }

        let token: String
        do {
            guard let storedToken = try await credentialProvider.readCredential(), !storedToken.isEmpty else {
                await handleMissingCredential()
                return
            }
            token = storedToken
        } catch {
            await handleMissingCredential()
            return
        }

        let tierBefore = state.tier
        do {
            let result = try await poller.poll(repository: state.repository, token: token)
            totalPollAttempts += 1
            if result.statusCode != 304 {
                quotaConsumingRequests += 1
            }
            observedActiveRun = observedActiveRun || result.hasActiveRun
            let now = await clock.now()
            apply(rateLimit: result.rateLimit, at: now)

            state.hasActiveRun = result.hasActiveRun
            state.latestCompletionAt = result.latestCompletionAt
            state.tier = Self.tier(
                repository: state.repository,
                hasActiveRun: state.hasActiveRun,
                latestCompletionAt: state.latestCompletionAt,
                now: now
            )
            state.lastPollAt = result.fetchedAt
            let schedule = await nextSchedule(tier: state.tier, from: now)
            state.nextPollAt = now.addingTimeInterval(schedule.interval)
            repositoryStates[key] = state
            lastSyncAt = result.fetchedAt

            await record(
                PollSchedulerEvent(
                    timestamp: result.fetchedAt,
                    repositoryKey: key,
                    trigger: trigger,
                    tierBefore: tierBefore,
                    tierAfter: state.tier,
                    scheduledInterval: schedule.interval,
                    jitterFactor: schedule.jitterFactor,
                    statusCode: result.statusCode,
                    cacheOutcome: result.cacheOutcome,
                    rateLimit: result.rateLimit,
                    hadActiveRun: result.hasActiveRun,
                    isRateLimitDegraded: isRateLimitDegraded,
                    errorCategory: nil
                )
            )
        } catch let error as GitHubClientError {
            totalPollAttempts += 1
            await handle(error: error, state: state, tierBefore: tierBefore, trigger: trigger)
        } catch {
            totalPollAttempts += 1
            await rescheduleAfterError(
                state: state,
                tierBefore: tierBefore,
                trigger: trigger,
                category: .transport
            )
        }
        await emitSnapshot()
    }

    private func handle(
        error: GitHubClientError,
        state: RepositoryState,
        tierBefore: PollingTier,
        trigger: PollTrigger
    ) async {
        switch error {
        case .authentication:
            hasAuthenticationFailure = true
            isRunning = false
            loopTask?.cancel()
            loopTask = nil
            await recordError(
                state: state,
                tierBefore: tierBefore,
                trigger: trigger,
                category: .authentication,
                scheduledInterval: 0,
                jitterFactor: 1
            )
        case let .accessDenied(repositoryKey, _):
            repositoryStates.removeValue(forKey: repositoryKey)
            await recordError(
                state: state,
                tierBefore: tierBefore,
                trigger: trigger,
                category: .accessDenied,
                scheduledInterval: 0,
                jitterFactor: 1
            )
        case let .primaryRateLimit(retryAt):
            let now = await clock.now()
            apply(rateLimit: GitHubRateLimit(remaining: 0, resetAt: retryAt), at: now)
            await rescheduleAfterError(
                state: state,
                tierBefore: tierBefore,
                trigger: trigger,
                category: .primaryRateLimit
            )
        default:
            await rescheduleAfterError(
                state: state,
                tierBefore: tierBefore,
                trigger: trigger,
                category: error.category
            )
        }
    }

    private func rescheduleAfterError(
        state originalState: RepositoryState,
        tierBefore: PollingTier,
        trigger: PollTrigger,
        category: GitHubErrorCategory
    ) async {
        var state = originalState
        let now = await clock.now()
        let schedule = await nextSchedule(tier: state.tier, from: now)
        state.nextPollAt = now.addingTimeInterval(schedule.interval)
        state.lastPollAt = now
        repositoryStates[state.repository.key] = state
        lastSyncAt = now
        await recordError(
            state: state,
            tierBefore: tierBefore,
            trigger: trigger,
            category: category,
            scheduledInterval: schedule.interval,
            jitterFactor: schedule.jitterFactor
        )
    }

    private func recordError(
        state: RepositoryState,
        tierBefore: PollingTier,
        trigger: PollTrigger,
        category: GitHubErrorCategory,
        scheduledInterval: TimeInterval,
        jitterFactor: Double
    ) async {
        await record(
            PollSchedulerEvent(
                timestamp: await clock.now(),
                repositoryKey: state.repository.key,
                trigger: trigger,
                tierBefore: tierBefore,
                tierAfter: state.tier,
                scheduledInterval: scheduledInterval,
                jitterFactor: jitterFactor,
                statusCode: nil,
                cacheOutcome: .none,
                rateLimit: latestRateLimit,
                hadActiveRun: state.hasActiveRun,
                isRateLimitDegraded: isRateLimitDegraded,
                errorCategory: category
            )
        )
    }

    private func handleMissingCredential() async {
        hasAuthenticationFailure = true
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        await emitSnapshot()
    }

    private func apply(rateLimit: GitHubRateLimit, at now: Date) {
        latestRateLimit = rateLimit
        guard let remaining = rateLimit.remaining else { return }
        let wasDegraded = isRateLimitDegraded
        isRateLimitDegraded = remaining < Self.degradationThreshold
        guard wasDegraded != isRateLimitDegraded else { return }

        let multiplier = isRateLimitDegraded
            ? Self.degradedIntervalMultiplier
            : 1 / Self.degradedIntervalMultiplier
        for key in repositoryStates.keys {
            guard var state = repositoryStates[key] else { continue }
            let remainingDelay = max(0, state.nextPollAt.timeIntervalSince(now))
            state.nextPollAt = now.addingTimeInterval(remainingDelay * multiplier)
            repositoryStates[key] = state
        }
    }

    private func nextSchedule(tier: PollingTier, from _: Date) async -> (interval: TimeInterval, jitterFactor: Double) {
        let unit = min(1, max(0, await randomSource.nextUnitInterval()))
        let jitterFactor = (1 - Self.jitterRange) + (2 * Self.jitterRange * unit)
        let degradation = isRateLimitDegraded ? Self.degradedIntervalMultiplier : 1
        return (tier.baseInterval * degradation * jitterFactor, jitterFactor)
    }

    private func record(_ event: PollSchedulerEvent) async {
        guard let recorder else { return }
        try? await recorder.recordSchedulerEvent(event, sessionID: sessionID)
    }

    private func emitSnapshot() async {
        guard let eventHandler else { return }
        await eventHandler(makeSnapshot())
    }

    private func makeSnapshot() -> PollSchedulerSnapshot {
        let repositories = repositoryStates.values
            .map {
                PollRepositorySnapshot(
                    repositoryKey: $0.repository.key,
                    tier: $0.tier,
                    nextPollAt: $0.nextPollAt,
                    lastPollAt: $0.lastPollAt,
                    hasActiveRun: $0.hasActiveRun
                )
            }
            .sorted { $0.repositoryKey < $1.repositoryKey }
        return PollSchedulerSnapshot(
            isRunning: isRunning,
            isRateLimitDegraded: isRateLimitDegraded,
            hasAuthenticationFailure: hasAuthenticationFailure,
            rateLimit: latestRateLimit,
            lastSyncAt: lastSyncAt,
            totalPollAttempts: totalPollAttempts,
            quotaConsumingRequests: quotaConsumingRequests,
            sessionStartedAt: sessionStartedAt,
            sessionRepositoryCount: sessionRepositoryCount,
            observedActiveRun: observedActiveRun,
            repositories: repositories
        )
    }

    private static func initialTier(repository: PollRepository, now: Date) -> PollingTier {
        tier(repository: repository, hasActiveRun: false, latestCompletionAt: nil, now: now)
    }

    private static func tier(
        repository: PollRepository,
        hasActiveRun: Bool,
        latestCompletionAt: Date?,
        now: Date
    ) -> PollingTier {
        if hasActiveRun { return .hot }
        let recentActivity = [repository.pushedAt, latestCompletionAt].compactMap { $0 }.max()
        if let recentActivity, now.timeIntervalSince(recentActivity) <= warmWindow {
            return .warm
        }
        return .cold
    }
}
