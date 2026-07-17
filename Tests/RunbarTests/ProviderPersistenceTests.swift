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
