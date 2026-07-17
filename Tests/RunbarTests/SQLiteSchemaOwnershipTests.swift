import Foundation
import XCTest
@testable import Runbar

/// Guards the schema-ownership fix: every store applies the whole canonical
/// schema on open, so construction order no longer matters and no store depends
/// on another having run first.
final class SQLiteSchemaOwnershipTests: XCTestCase {
    private func makeDatabasePath() throws -> (path: String, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarSchemaOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory.appendingPathComponent("runbar.sqlite3").path,
            { try? FileManager.default.removeItem(at: directory) }
        )
    }

    /// Opening the git-watcher store first used to throw: its migration issued
    /// `ALTER TABLE repos` against a `repos` table that only `SQLiteStore`
    /// created. It must now succeed on a fresh database with no other store open.
    func testGitWatcherStoreOpensBeforeDiscoveryStore() throws {
        let (path, cleanup) = try makeDatabasePath()
        defer { cleanup() }
        XCTAssertNoThrow(try SQLiteGitWatcherStore(path: path))
    }

    /// Opening the menu-bar store first used to depend on the poll store having
    /// created `runs`; loading must now work with no other store constructed.
    func testMenuBarStoreLoadsWithNoOtherStoreConstructed() async throws {
        let (path, cleanup) = try makeDatabasePath()
        defer { cleanup() }
        let menuStore = try SQLiteMenuBarStore(path: path)
        let snapshot = try await menuStore.loadMenuBarRuns()
        XCTAssertTrue(snapshot.running.isEmpty)
        XCTAssertTrue(snapshot.recent.isEmpty)
    }

    /// A cross-store operation that previously needed a specific open order:
    /// the git-watcher store writes `repos.current_sha`, a column on a table the
    /// discovery store owns. Opening the watcher store *before* the discovery
    /// store must still leave both able to read and write the shared table.
    func testCrossStoreColumnWorksRegardlessOfOpenOrder() async throws {
        let (path, cleanup) = try makeDatabasePath()
        defer { cleanup() }
        let identity = RepoIdentity(owner: "owner", name: "repo")

        // Watcher first — the previously fatal order.
        let watcherStore = try SQLiteGitWatcherStore(path: path)
        let discoveryStore = try SQLiteStore(path: path)

        try await discoveryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(
                codeRootPath: "/tmp",
                repositories: [
                    DiscoveredRepository(
                        identity: identity,
                        source: .local,
                        localPath: "/tmp/repo",
                        pushedAt: nil,
                        workflows: [],
                        isExcluded: false,
                        isAccessible: true
                    )
                ],
                skippedLocalRepositories: []
            )
        )

        let sha = String(repeating: "a", count: 40)
        try await watcherStore.updateCurrentSHA(sha, repositoryKey: identity.normalizedKey)
        let readBack = try await watcherStore.currentSHA(repositoryKey: identity.normalizedKey)
        XCTAssertEqual(readBack, sha)
    }

    /// `repo_preferences` used to be created by two different stores. Whichever
    /// opens, the table exists exactly once and preferences round-trip.
    func testRepoPreferencesAvailableFromDiscoveryStoreAlone() async throws {
        let (path, cleanup) = try makeDatabasePath()
        defer { cleanup() }
        let store = try SQLiteStore(path: path)
        let identity = RepoIdentity(owner: "owner", name: "repo")

        try await store.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(
                codeRootPath: "/tmp",
                repositories: [
                    DiscoveredRepository(
                        identity: identity,
                        source: .local,
                        localPath: "/tmp/repo",
                        pushedAt: nil,
                        workflows: [],
                        isExcluded: false,
                        isAccessible: true
                    )
                ],
                skippedLocalRepositories: []
            )
        )
        try await store.setExcluded(true, repositoryKey: identity.normalizedKey)
        let prefs = try await store.repositoryPreferences()
        XCTAssertEqual(prefs[identity.normalizedKey]?.isExcluded, true)
    }
}
