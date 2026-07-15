import Foundation

actor GitWatcher {
    private struct RepositoryState {
        let repository: GitWatchRepository
        let metadata: GitRepositoryMetadata
        var snapshot: GitWatchSnapshot
        let streamTask: Task<Void, Never>
    }

    private struct PendingEvaluation {
        let detectedAt: Date
        let task: Task<Void, Never>
    }

    private let resolver: GitMetadataResolver
    private let eventSource: any GitFileEventSourcing
    private let localPushPoller: any LocalPushPolling
    private let recorder: any GitWatcherRecording
    private let coalescingDelay: Duration

    private var repositoryStates: [String: RepositoryState] = [:]
    private var pendingEvaluations: [String: PendingEvaluation] = [:]

    init(
        resolver: GitMetadataResolver = GitMetadataResolver(),
        eventSource: any GitFileEventSourcing = FSEventsGitFileEventSource(),
        localPushPoller: any LocalPushPolling,
        recorder: any GitWatcherRecording,
        coalescingDelay: Duration = .milliseconds(150)
    ) {
        self.resolver = resolver
        self.eventSource = eventSource
        self.localPushPoller = localPushPoller
        self.recorder = recorder
        self.coalescingDelay = coalescingDelay
    }

    deinit {
        for state in repositoryStates.values {
            state.streamTask.cancel()
        }
        for pending in pendingEvaluations.values {
            pending.task.cancel()
        }
    }

    func configure(repositories: [GitWatchRepository]) async {
        let incoming = Dictionary(uniqueKeysWithValues: repositories.map { ($0.key, $0) })
        for key in repositoryStates.keys where incoming[key] == nil {
            repositoryStates.removeValue(forKey: key)?.streamTask.cancel()
            pendingEvaluations.removeValue(forKey: key)?.task.cancel()
        }

        for repository in incoming.values.sorted(by: { $0.key < $1.key }) {
            guard let metadata = try? resolver.resolve(repositoryPath: repository.localPath),
                  let snapshot = try? resolver.snapshot(metadata: metadata)
            else { continue }

            if let existing = repositoryStates[repository.key],
               existing.repository == repository,
               existing.metadata == metadata {
                if existing.snapshot.currentSHA != snapshot.currentSHA {
                    try? await recorder.updateCurrentSHA(snapshot.currentSHA, repositoryKey: repository.key)
                    var updated = existing
                    updated.snapshot = GitWatchSnapshot(
                        looseRemoteRefsFingerprint: existing.snapshot.looseRemoteRefsFingerprint,
                        hasLooseRemoteReference: existing.snapshot.hasLooseRemoteReference,
                        packedRefsFingerprint: existing.snapshot.packedRefsFingerprint,
                        currentSHA: snapshot.currentSHA
                    )
                    repositoryStates[repository.key] = updated
                }
                continue
            }

            repositoryStates.removeValue(forKey: repository.key)?.streamTask.cancel()
            try? await recorder.updateCurrentSHA(snapshot.currentSHA, repositoryKey: repository.key)
            let paths = metadata.watchRootPaths
            let source = eventSource
            let task = Task { [weak self] in
                for await batch in source.events(for: paths) {
                    guard !Task.isCancelled else { return }
                    await self?.receive(batch: batch, repositoryKey: repository.key)
                }
            }
            repositoryStates[repository.key] = RepositoryState(
                repository: repository,
                metadata: metadata,
                snapshot: snapshot,
                streamTask: task
            )
        }
    }

    func stop() {
        for state in repositoryStates.values {
            state.streamTask.cancel()
        }
        for pending in pendingEvaluations.values {
            pending.task.cancel()
        }
        repositoryStates.removeAll()
        pendingEvaluations.removeAll()
    }

    func processFileEvents(repositoryKey: String, detectedAt: Date = Date()) async {
        guard var state = repositoryStates[repositoryKey],
              let nextSnapshot = try? resolver.snapshot(metadata: state.metadata)
        else { return }

        let priorSnapshot = state.snapshot
        state.snapshot = nextSnapshot
        repositoryStates[repositoryKey] = state

        if priorSnapshot.currentSHA != nextSnapshot.currentSHA {
            try? await recorder.updateCurrentSHA(nextSnapshot.currentSHA, repositoryKey: repositoryKey)
        }

        let looseChanged = priorSnapshot.looseRemoteRefsFingerprint != nextSnapshot.looseRemoteRefsFingerprint
        let packedChanged = priorSnapshot.packedRefsFingerprint != nextSnapshot.packedRefsFingerprint
        guard looseChanged || packedChanged else { return }

        let signal: GitReferenceSignal
        switch (looseChanged, packedChanged) {
        case (true, true): signal = .looseAndPacked
        case (true, false): signal = .looseRemoteRef
        case (false, true): signal = .packedRefs
        case (false, false): return
        }

        let pollStartedAt = await localPushPoller.handleLocalPush(repositoryKey: repositoryKey)
        try? await recorder.recordGitWatcherEvent(
            GitWatcherEvent(
                repositoryKey: repositoryKey,
                signal: signal,
                referenceStorageBefore: priorSnapshot.referenceStorage,
                detectedAt: detectedAt,
                pollStartedAt: pollStartedAt,
                currentSHA: nextSnapshot.currentSHA
            )
        )
    }

    func watchedRepositoryCount() -> Int {
        repositoryStates.count
    }

    private func receive(batch: GitFileEventBatch, repositoryKey: String) {
        guard repositoryStates[repositoryKey] != nil else { return }
        let earliest = min(pendingEvaluations[repositoryKey]?.detectedAt ?? batch.detectedAt, batch.detectedAt)
        pendingEvaluations.removeValue(forKey: repositoryKey)?.task.cancel()
        let delay = coalescingDelay
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.flush(repositoryKey: repositoryKey, detectedAt: earliest)
        }
        pendingEvaluations[repositoryKey] = PendingEvaluation(detectedAt: earliest, task: task)
    }

    private func flush(repositoryKey: String, detectedAt: Date) async {
        pendingEvaluations.removeValue(forKey: repositoryKey)
        await processFileEvents(repositoryKey: repositoryKey, detectedAt: detectedAt)
    }
}
