import Foundation
import SQLite3
import XCTest
@testable import Runbar

final class SQLiteGitWatcherMigrationTests: XCTestCase {
    func testExistingM3DatabaseAddsWatcherStorageAndCurrentSHAColumns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitWatcherMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runbar.sqlite3").path
        let identity = RepoIdentity(owner: "owner", name: "repo")

        let discoveryStore = try SQLiteStore(path: path)
        try await discoveryStore.saveDiscoverySnapshot(
            RepoDiscoverySnapshot(
                codeRootPath: directory.path,
                repositories: [
                    DiscoveredRepository(
                        identity: identity,
                        source: .local,
                        localPath: directory.path,
                        pushedAt: nil,
                        workflows: [],
                        isExcluded: false,
                        isAccessible: true
                    )
                ],
                skippedLocalRepositories: []
            )
        )
        try createLegacyWatcherTable(path: path)

        let store = try SQLiteGitWatcherStore(path: path)
        let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sha = String(repeating: "b", count: 40)
        try await store.updateCurrentSHA(sha, repositoryKey: identity.normalizedKey)
        try await store.recordGitWatcherEvent(
            GitWatcherEvent(
                repositoryKey: identity.normalizedKey,
                signal: .packedRefs,
                referenceStorageBefore: .packed,
                detectedAt: detectedAt,
                pollStartedAt: detectedAt.addingTimeInterval(0.2),
                currentSHA: sha
            )
        )

        let entries = try await store.debugEntries()
        let persistedSHA = try await store.currentSHA(repositoryKey: identity.normalizedKey)
        XCTAssertEqual(persistedSHA, sha)
        XCTAssertEqual(entries.first?.referenceStorageBefore, .packed)
    }

    private func createLegacyWatcherTable(path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteStoreError.open("Could not create legacy test database")
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE git_watcher_debug (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repo_key TEXT NOT NULL,
            signal TEXT NOT NULL,
            detected_at REAL NOT NULL,
            poll_started_at REAL,
            latency_ms INTEGER,
            current_sha TEXT
        );
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.statement(String(cString: sqlite3_errmsg(database)))
        }
    }
}
