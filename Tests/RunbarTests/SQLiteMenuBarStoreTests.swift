import XCTest
@testable import Runbar

final class SQLiteMenuBarStoreTests: XCTestCase {
    func testLoadsMergedActiveAndTwentyRecentRunsWithLocalHEADAccent() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repositoryStore = try SQLiteStore(path: databaseURL.path)
        let pollStore = try SQLitePollStore(path: databaseURL.path)
        let watcherStore = try SQLiteGitWatcherStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let repositories = [
            repository(owner: "alpha", name: "one"),
            repository(owner: "beta", name: "two")
        ]
        try await repositoryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(codeRootPath: nil, repositories: repositories, skippedLocalRepositories: [])
        )
        try await watcherStore.updateCurrentSHA("local-sha", repositoryKey: repositories[0].id)

        let now = Date()
        var runs: [WorkflowRun] = [
            workflowRun(id: 900, repository: repositories[0], status: "in_progress", conclusion: nil, createdAt: now, sha: "local-sha"),
            workflowRun(id: 901, repository: repositories[1], status: "queued", conclusion: nil, createdAt: now.addingTimeInterval(-1), sha: "queued-sha")
        ]
        runs += (0..<25).map { index in
            workflowRun(
                id: Int64(index + 1),
                repository: repositories[index % 2],
                status: "completed",
                conclusion: index == 0 ? "failure" : "success",
                createdAt: now.addingTimeInterval(TimeInterval(-index * 10)),
                sha: index == 0 ? "local-sha" : "sha-\(index)"
            )
        }
        try await pollStore.saveWorkflowRuns(runs.filter { $0.repositoryKey == repositories[0].id }, for: repositories[0].id)
        try await pollStore.saveWorkflowRuns(runs.filter { $0.repositoryKey == repositories[1].id }, for: repositories[1].id)

        let snapshot = try await menuStore.loadMenuBarRuns(recentLimit: 20)

        XCTAssertEqual(snapshot.running.map(\.id), [900, 901])
        XCTAssertEqual(snapshot.recent.count, 20)
        XCTAssertEqual(snapshot.recent.map(\.id), Array(1...20).map(Int64.init))
        XCTAssertEqual(Set(snapshot.recent.map { item in item.repository.fullName }), ["alpha/one", "beta/two"])
        XCTAssertEqual(snapshot.recent.first?.repository.fullName, "alpha/one")
        XCTAssertEqual(snapshot.recent.first?.matchesLocalHEAD, true)
        XCTAssertEqual(snapshot.recent.dropFirst().filter(\.matchesLocalHEAD).count, 0)

        let tick = MenuBarTimerTick(
            timestamp: now.addingTimeInterval(5),
            runID: 900,
            elapsedSeconds: 5,
            source: MenuBarTimerTick.localSource
        )
        try await menuStore.recordMenuBarTimerTick(tick)
        let persistedTicks = try await menuStore.timerTicks()
        XCTAssertEqual(persistedTicks.count, 1)
        XCTAssertEqual(persistedTicks.first?.timestamp.timeIntervalSince1970 ?? 0, tick.timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(persistedTicks.first?.runID, tick.runID)
        XCTAssertEqual(persistedTicks.first?.elapsedSeconds, tick.elapsedSeconds)
        XCTAssertEqual(persistedTicks.first?.source, tick.source)
    }

    func testActiveRunMedianUsesOnlyTenMostRecentCompletedRunsOfSameWorkflow() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repositoryStore = try SQLiteStore(path: databaseURL.path)
        let pollStore = try SQLitePollStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let repository = repository(owner: "median", name: "fixture")
        try await repositoryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(codeRootPath: nil, repositories: [repository], skippedLocalRepositories: [])
        )

        let now = Date()
        var runs = (0..<12).map { index in
            let duration = TimeInterval((index + 1) * 10)
            let completedAt = now.addingTimeInterval(TimeInterval(-index * 1_000))
            return WorkflowRun(
                id: Int64(index + 1),
                repositoryKey: repository.id,
                workflowID: 77,
                workflowName: "Median CI",
                status: "completed",
                conclusion: "success",
                runStartedAt: completedAt.addingTimeInterval(-duration),
                createdAt: completedAt.addingTimeInterval(-duration),
                updatedAt: completedAt,
                headBranch: "main",
                headSHA: "history-\(index)",
                event: "push",
                displayTitle: "Median CI",
                htmlURL: "https://github.com/median/fixture/actions/runs/\(index + 1)",
                runAttempt: 1,
                actorLogin: nil,
                triggeringActorLogin: nil
            )
        }
        runs.append(
            WorkflowRun(
                id: 99,
                repositoryKey: repository.id,
                workflowID: 77,
                workflowName: "Median CI",
                status: "in_progress",
                conclusion: nil,
                runStartedAt: now.addingTimeInterval(-20),
                createdAt: now.addingTimeInterval(-20),
                updatedAt: now,
                headBranch: "main",
                headSHA: "active",
                event: "workflow_dispatch",
                displayTitle: "Median CI",
                htmlURL: "https://github.com/median/fixture/actions/runs/99",
                runAttempt: 1,
                actorLogin: nil,
                triggeringActorLogin: nil
            )
        )
        try await pollStore.saveWorkflowRuns(runs, for: repository.id)

        let snapshot = try await menuStore.loadMenuBarRuns(recentLimit: 20)

        XCTAssertEqual(snapshot.running.count, 1)
        XCTAssertEqual(snapshot.running[0].medianDurationSeconds, 55)
        XCTAssertTrue(snapshot.recent.allSatisfy { $0.medianDurationSeconds == nil })
    }

    /// A run GitHub stops listing — deleted from the Actions UI, or pushed out
    /// of the 20 most recent — used to sit in the menu spinning until the 30-day
    /// prune, because an upsert can only update rows the response still
    /// mentions. Saving must reconcile it away, while leaving runs the response
    /// still reports (and other repositories' runs) alone.
    func testSaveClearsUnfinishedRunsGitHubNoLongerReports() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repositoryStore = try SQLiteStore(path: databaseURL.path)
        let pollStore = try SQLitePollStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let repositories = [
            repository(owner: "alpha", name: "one"),
            repository(owner: "beta", name: "two")
        ]
        try await repositoryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(codeRootPath: nil, repositories: repositories, skippedLocalRepositories: [])
        )

        let now = Date()
        let vanishing = workflowRun(
            id: 500, repository: repositories[0], status: "in_progress",
            conclusion: nil, createdAt: now, sha: "gone"
        )
        let surviving = workflowRun(
            id: 501, repository: repositories[0], status: "in_progress",
            conclusion: nil, createdAt: now, sha: "still-going"
        )
        let otherRepo = workflowRun(
            id: 502, repository: repositories[1], status: "in_progress",
            conclusion: nil, createdAt: now, sha: "elsewhere"
        )
        try await pollStore.saveWorkflowRuns([vanishing, surviving], for: repositories[0].id)
        try await pollStore.saveWorkflowRuns([otherRepo], for: repositories[1].id)
        var running = try await menuStore.loadMenuBarRuns(recentLimit: 20).running
        XCTAssertEqual(Set(running.map(\.id)), [500, 501, 502])

        // Next poll of repo one no longer lists 500 at all.
        try await pollStore.saveWorkflowRuns([surviving], for: repositories[0].id)

        running = try await menuStore.loadMenuBarRuns(recentLimit: 20).running
        XCTAssertFalse(running.map(\.id).contains(500), "a run GitHub stopped reporting must not stay running")
        XCTAssertTrue(running.map(\.id).contains(501), "a run still reported must survive")
        XCTAssertTrue(running.map(\.id).contains(502), "another repository's runs must be untouched")
    }

    /// Completed runs are history, not liveness: reconciliation must only touch
    /// unfinished rows, or the Recent list would empty out as runs age past the
    /// 20 the poll returns.
    func testSaveKeepsCompletedRunsMissingFromTheResponse() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repositoryStore = try SQLiteStore(path: databaseURL.path)
        let pollStore = try SQLitePollStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let repo = repository(owner: "alpha", name: "one")
        try await repositoryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(codeRootPath: nil, repositories: [repo], skippedLocalRepositories: [])
        )

        let now = Date()
        let older = workflowRun(
            id: 600, repository: repo, status: "completed",
            conclusion: "success", createdAt: now.addingTimeInterval(-600), sha: "older"
        )
        try await pollStore.saveWorkflowRuns([older], for: repo.id)
        // A later poll has scrolled past it entirely.
        let newer = workflowRun(
            id: 601, repository: repo, status: "completed",
            conclusion: "success", createdAt: now, sha: "newer"
        )
        try await pollStore.saveWorkflowRuns([newer], for: repo.id)

        let recent = try await menuStore.loadMenuBarRuns(recentLimit: 20).recent
        XCTAssertEqual(Set(recent.map(\.id)), [600, 601], "completed history must not be reconciled away")
    }

    private func repository(owner: String, name: String) -> DiscoveredRepository {
        DiscoveredRepository(
            identity: RepoIdentity(owner: owner, name: name),
            source: .both,
            localPath: "/tmp/\(name)",
            pushedAt: nil,
            workflows: [],
            isExcluded: false,
            isAccessible: true
        )
    }

    private func workflowRun(
        id: Int64,
        repository: DiscoveredRepository,
        status: String,
        conclusion: String?,
        createdAt: Date,
        sha: String
    ) -> WorkflowRun {
        WorkflowRun(
            id: id,
            repositoryKey: repository.id,
            workflowID: id + 1_000,
            workflowName: "CI \(id)",
            status: status,
            conclusion: conclusion,
            runStartedAt: status == "queued" ? nil : createdAt,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(5),
            headBranch: "main",
            headSHA: sha,
            event: "push",
            displayTitle: "Build",
            htmlURL: "https://github.com/\(repository.identity.fullName)/actions/runs/\(id)",
            runAttempt: 1,
            actorLogin: "octocat",
            triggeringActorLogin: "octocat"
        )
    }

    private func temporaryDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runbar-m5-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("runbar.sqlite3")
    }
}
