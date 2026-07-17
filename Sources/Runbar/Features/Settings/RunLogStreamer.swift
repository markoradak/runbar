import Foundation

/// Owns run-log presentation: the one-shot failure log fetched for a completed
/// run, and the live tail streamed while a run is in progress. Extracted from
/// `SettingsModel` so its state and its Task lifecycle live in one place.
///
/// It keeps its own copy of the two pieces of context the live loop needs — the
/// panel's visibility and the current set of running cards — which `SettingsModel`
/// pushes in via `setMenuBarVisible` and `updateRunning`. `SettingsModel` owns an
/// instance and forwards its `objectWillChange` so views observing the model still
/// re-render on log updates.
@MainActor
final class RunLogStreamer: ObservableObject {
    @Published private(set) var failureLogs: [Int64: RunFailureLogState] = [:]
    @Published private(set) var liveLogs: [Int64: RunFailureLogState] = [:]
    @Published private(set) var expandedLiveLogRunIDs: Set<Int64> = []

    private let credentialProvider: any PollCredentialProviding
    private let githubClient: GitHubClient?
    private let workflowJobsLoader: (any WorkflowJobsLoading)?
    private let providerMonitor: ExternalProviderMonitor?

    private var liveLogTasks: [Int64: Task<Void, Never>] = [:]
    private var isMenuBarVisible = false
    private var running: [MenuBarRun] = []

    init(
        credentialProvider: any PollCredentialProviding,
        githubClient: GitHubClient?,
        workflowJobsLoader: (any WorkflowJobsLoading)?,
        providerMonitor: ExternalProviderMonitor?
    ) {
        self.credentialProvider = credentialProvider
        self.githubClient = githubClient
        self.workflowJobsLoader = workflowJobsLoader
        self.providerMonitor = providerMonitor
    }

    deinit {
        for task in liveLogTasks.values { task.cancel() }
    }

    // MARK: - Context pushed in by SettingsModel

    /// The current running cards. A live loop stops once its run leaves this set.
    func updateRunning(_ running: [MenuBarRun]) {
        self.running = running
    }

    /// Resumes streams for expanded running cards when the panel opens; pauses
    /// them when it closes, keeping expansion state so reopening resumes.
    func setMenuBarVisible(_ visible: Bool) {
        isMenuBarVisible = visible
        if visible {
            for item in running where expandedLiveLogRunIDs.contains(item.id) {
                startLiveLog(for: item)
            }
        } else {
            for task in liveLogTasks.values { task.cancel() }
            liveLogTasks.removeAll()
        }
    }

    // MARK: - Failure logs

    func failureLogState(for runID: Int64) -> RunFailureLogState {
        failureLogs[runID] ?? .idle
    }

    func expandFailureLog(for item: MenuBarRun) {
        switch failureLogState(for: item.id) {
        case .idle, .failed:
            Task { await loadFailureLog(for: item) }
        case .loading, .loaded:
            break
        }
    }

    func loadFailureLog(for item: MenuBarRun) async {
        failureLogs[item.id] = .loading
        do {
            switch item.run.provider {
            case .githubActions:
                failureLogs[item.id] = .loaded(try await loadGitHubFailureLog(for: item))
            case .vercel, .cloudflarePages:
                guard let providerMonitor else { throw ProviderClientError.transport }
                let lines = try await providerMonitor.executionLogLines(
                    provider: item.run.provider,
                    externalID: item.run.externalID,
                    projectKey: item.run.projectKey ?? item.run.repositoryKey
                )
                failureLogs[item.id] = .loaded(
                    RunFailureLog(
                        jobName: nil,
                        stepName: nil,
                        lines: FailureLogText.tail(lines),
                        webURL: item.run.htmlURL
                    )
                )
            }
        } catch {
            failureLogs[item.id] = .failed("Runbar could not fetch the failure log.")
        }
    }

    // MARK: - Live logs

    func liveLogState(for runID: Int64) -> RunFailureLogState {
        liveLogs[runID] ?? .idle
    }

    func toggleLiveLog(for item: MenuBarRun) {
        if expandedLiveLogRunIDs.contains(item.id) {
            expandedLiveLogRunIDs.remove(item.id)
            liveLogTasks[item.id]?.cancel()
            liveLogTasks.removeValue(forKey: item.id)
        } else {
            expandedLiveLogRunIDs.insert(item.id)
            startLiveLog(for: item)
        }
    }

    private func startLiveLog(for item: MenuBarRun) {
        guard liveLogTasks[item.id] == nil else { return }
        if liveLogs[item.id] == nil { liveLogs[item.id] = .loading }
        liveLogTasks[item.id] = Task { [weak self] in
            await self?.runLiveLogLoop(for: item)
        }
    }

    private func runLiveLogLoop(for item: MenuBarRun) async {
        while !Task.isCancelled {
            guard isMenuBarVisible,
                  running.contains(where: { $0.id == item.id })
            else { break }
            do {
                let lines = try await fetchLiveLogLines(for: item)
                if !Task.isCancelled, !lines.isEmpty {
                    liveLogs[item.id] = .loaded(
                        RunFailureLog(jobName: nil, stepName: nil, lines: lines, webURL: item.run.htmlURL)
                    )
                }
            } catch {
                // Keep the last streamed lines on transient errors; before the
                // first payload (e.g. still queued) stay in the loading state.
            }
            try? await Task.sleep(for: .seconds(4))
        }
        liveLogTasks.removeValue(forKey: item.id)
    }

    private func fetchLiveLogLines(for item: MenuBarRun) async throws -> [String] {
        switch item.run.provider {
        case .githubActions:
            guard let githubClient, let workflowJobsLoader else { throw GitHubClientError.transport }
            guard let token = try await credentialProvider.readCredential(), !token.isEmpty else {
                throw GitHubClientError.authentication
            }
            let jobs = try await workflowJobsLoader.loadJobs(for: item, token: token).jobs
            guard let job = jobs.first(where: { $0.status == "in_progress" }) ?? jobs.last else {
                throw GitHubClientError.decoding
            }
            let text = try await githubClient.fetchJobLogText(
                repository: item.repository,
                jobID: job.id,
                token: token
            )
            return FailureLogText.tail(text)
        case .vercel, .cloudflarePages:
            guard let providerMonitor else { throw ProviderClientError.transport }
            let lines = try await providerMonitor.executionLogLines(
                provider: item.run.provider,
                externalID: item.run.externalID,
                projectKey: item.run.projectKey ?? item.run.repositoryKey
            )
            return FailureLogText.tail(lines)
        }
    }

    private func loadGitHubFailureLog(for item: MenuBarRun) async throws -> RunFailureLog {
        guard let githubClient, let workflowJobsLoader else { throw GitHubClientError.transport }
        guard let token = try await credentialProvider.readCredential(), !token.isEmpty else {
            throw GitHubClientError.authentication
        }
        let jobs = try await workflowJobsLoader.loadJobs(for: item, token: token).jobs
        guard let failedJob = jobs.first(where: { WorkflowRunPresentation.isFailure($0.conclusion) }) else {
            throw GitHubClientError.decoding
        }
        let failedStep = failedJob.steps.first(where: { WorkflowRunPresentation.isFailure($0.conclusion) })
        let logText = try await githubClient.fetchJobLogText(
            repository: item.repository,
            jobID: failedJob.id,
            token: token
        )
        return RunFailureLog(
            jobName: failedJob.name,
            stepName: failedStep?.name,
            lines: FailureLogText.failureTail(logText),
            webURL: failedJob.htmlURL ?? item.run.htmlURL
        )
    }
}
