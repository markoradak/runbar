import Foundation
import XCTest
@testable import Runbar

final class ProviderPersistenceTests: XCTestCase {
    func testProviderExecutionsMergeWithGitHubRunsAndMatchLocalHEAD() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let repositoryStore = try SQLiteStore(path: databaseURL.path)
        let watcherStore = try SQLiteGitWatcherStore(path: databaseURL.path)
        let providerStore = try SQLiteProviderStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let repository = DiscoveredRepository(
            identity: RepoIdentity(owner: "owner", name: "site"),
            source: .local,
            localPath: "/tmp/site",
            pushedAt: nil,
            workflows: [],
            isExcluded: false,
            isAccessible: true
        )
        try await repositoryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(codeRootPath: nil, repositories: [repository], skippedLocalRepositories: [])
        )
        try await watcherStore.updateCurrentSHA("local-sha", repositoryKey: repository.id)
        let now = Date()
        let active = execution(
            provider: .vercel,
            id: "dpl_active",
            project: "site",
            status: "in_progress",
            conclusion: nil,
            createdAt: now,
            updatedAt: now,
            sha: "local-sha"
        )
        let completed = execution(
            provider: .cloudflarePages,
            id: "cf_completed",
            project: "site",
            status: "completed",
            conclusion: "success",
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-30),
            sha: "older-sha"
        )
        try await providerStore.saveProviderExecutions([active], provider: .vercel)
        try await providerStore.saveProviderExecutions([completed], provider: .cloudflarePages)

        let snapshot = try await menuStore.loadMenuBarRuns(recentLimit: 20)

        XCTAssertEqual(snapshot.running.count, 1)
        XCTAssertEqual(snapshot.running[0].run.provider, .vercel)
        XCTAssertEqual(snapshot.running[0].run.externalID, "dpl_active")
        XCTAssertEqual(snapshot.running[0].matchesLocalHEAD, true)
        XCTAssertTrue(snapshot.running[0].id < 0)
        XCTAssertEqual(snapshot.recent.count, 1)
        XCTAssertEqual(snapshot.recent[0].run.provider, .cloudflarePages)
        XCTAssertEqual(snapshot.recent[0].run.conclusion, "success")
        XCTAssertFalse(snapshot.recent[0].run.supportsJobs)
        XCTAssertEqual(
            StableProviderID.run(provider: .vercel, externalID: "dpl_active"),
            active.syntheticID
        )
    }

    func testDisconnectDeletesOnlySelectedProviderHistory() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let providerStore = try SQLiteProviderStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let now = Date()
        try await providerStore.saveProviderExecutions(
            [execution(provider: .vercel, id: "v", project: "v", status: "completed", conclusion: "success", createdAt: now, updatedAt: now, sha: "")],
            provider: .vercel
        )
        try await providerStore.saveProviderExecutions(
            [execution(provider: .cloudflarePages, id: "c", project: "c", status: "completed", conclusion: "success", createdAt: now.addingTimeInterval(-1), updatedAt: now, sha: "")],
            provider: .cloudflarePages
        )

        try await providerStore.deleteProviderExecutions(provider: .vercel)
        let snapshot = try await menuStore.loadMenuBarRuns(recentLimit: 20)

        XCTAssertEqual(snapshot.recent.map(\.run.provider), [.cloudflarePages])
    }

    func testSaveDropsZeroDurationCancelledDeploymentsAndKeepsRealOnes() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let providerStore = try SQLiteProviderStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let now = Date()
        // Phantom: auto-skipped, cancelled with no elapsed time. Real: cancelled
        // after building. Only the real one should survive a save.
        let phantom = execution(
            provider: .vercel, id: "dpl_skipped", project: "landing",
            status: "completed", conclusion: "cancelled",
            createdAt: now, updatedAt: now, sha: ""
        )
        let realCancel = execution(
            provider: .vercel, id: "dpl_realcancel", project: "landing",
            status: "completed", conclusion: "cancelled",
            createdAt: now.addingTimeInterval(-60), updatedAt: now.addingTimeInterval(-30), sha: ""
        )
        try await providerStore.saveProviderExecutions([phantom, realCancel], provider: .vercel)

        let snapshot = try await menuStore.loadMenuBarRuns(recentLimit: 20)
        let ids = snapshot.recent.map(\.run.externalID)
        XCTAssertFalse(ids.contains("dpl_skipped"), "zero-duration cancelled deployment should be purged")
        XCTAssertTrue(ids.contains("dpl_realcancel"), "a cancellation that actually built should survive")
    }

    /// A deployment stored while queued and then dropped at ingest — Vercel
    /// auto-skipping it via its ignored build step — used to be updated by
    /// nothing ever again, stranding a permanently "running" card in the menu
    /// until the 30-day prune. A save reconciles it away.
    func testSaveClearsUnfinishedRunsMissingFromTheFetch() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let providerStore = try SQLiteProviderStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let now = Date()
        let queued = execution(
            provider: .vercel, id: "dpl_autoskipped", project: "landing",
            status: "queued", conclusion: nil,
            createdAt: now, updatedAt: now, sha: ""
        )
        let stillBuilding = execution(
            provider: .vercel, id: "dpl_building", project: "landing",
            status: "in_progress", conclusion: nil,
            createdAt: now, updatedAt: now, sha: ""
        )
        try await providerStore.saveProviderExecutions([queued, stillBuilding], provider: .vercel)
        var running = try await menuStore.loadMenuBarRuns(recentLimit: 20).running
        XCTAssertEqual(Set(running.map(\.run.externalID)), ["dpl_autoskipped", "dpl_building"])

        // Next fetch: the auto-skipped one is gone from the response entirely,
        // the other has progressed to a finished state.
        let finished = execution(
            provider: .vercel, id: "dpl_building", project: "landing",
            status: "completed", conclusion: "success",
            createdAt: now, updatedAt: now.addingTimeInterval(30), sha: ""
        )
        try await providerStore.saveProviderExecutions([finished], provider: .vercel)

        let snapshot = try await menuStore.loadMenuBarRuns(recentLimit: 20)
        running = snapshot.running
        XCTAssertTrue(running.isEmpty, "a run absent from the fetch must not stay running forever")
        XCTAssertEqual(snapshot.recent.map(\.run.externalID), ["dpl_building"])
        XCTAssertEqual(snapshot.recent.first?.run.conclusion, "success")
    }

    /// Reconciling one provider's unfinished runs must not disturb another's.
    func testSaveLeavesOtherProvidersUnfinishedRunsAlone() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let providerStore = try SQLiteProviderStore(path: databaseURL.path)
        let menuStore = try SQLiteMenuBarStore(path: databaseURL.path)
        let now = Date()
        let cloudflare = execution(
            provider: .cloudflarePages, id: "cf_building", project: "docs",
            status: "in_progress", conclusion: nil,
            createdAt: now, updatedAt: now, sha: ""
        )
        try await providerStore.saveProviderExecutions([cloudflare], provider: .cloudflarePages)
        try await providerStore.saveProviderExecutions([], provider: .vercel)

        let running = try await menuStore.loadMenuBarRuns(recentLimit: 20).running
        XCTAssertEqual(running.map(\.run.externalID), ["cf_building"])
    }

    private func execution(
        provider: ExecutionProvider,
        id: String,
        project: String,
        status: String,
        conclusion: String?,
        createdAt: Date,
        updatedAt: Date,
        sha: String
    ) -> ProviderExecution {
        ProviderExecution(
            provider: provider,
            externalID: id,
            repository: RepoIdentity(owner: "owner", name: project),
            projectKey: "scope/" + project,
            projectName: project,
            status: status,
            conclusion: conclusion,
            startedAt: createdAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            headBranch: "main",
            headSHA: sha,
            environment: "Production",
            displayTitle: "Deploy " + project,
            webURL: "https://example.com/" + id
        )
    }

    private func temporaryDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runbar-provider-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("runbar.sqlite3")
    }
}
