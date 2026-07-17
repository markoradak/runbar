import Foundation
import SQLite3
import XCTest
@testable import Runbar

final class SQLiteGitWatcherMigrationTests: XCTestCase {
    /// An on-disk database created by an older build lacks `repos.current_sha`
    /// and `git_watcher_debug.reference_storage_before`. Opening *any* store now
    /// applies the full canonical schema, and its guarded column migrations must
    /// add both to the pre-existing legacy tables.
    func testLegacyDatabaseIsMigratedWhenAnyStoreOpens() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunbarGitWatcherMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runbar.sqlite3").path
        let identity = RepoIdentity(owner: "owner", name: "repo")

        // Simulate an older database: both tables exist but predate the columns.
        try createLegacyDatabase(path: path, repositoryKey: identity.normalizedKey)
        try assertColumnAbsent("current_sha", table: "repos", path: path)
        try assertColumnAbsent("reference_storage_before", table: "git_watcher_debug", path: path)

        // Opening a store runs the canonical schema + column migrations.
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
        XCTAssertEqual(persistedSHA, sha, "current_sha column was not migrated")
        XCTAssertEqual(entries.first?.referenceStorageBefore, .packed, "reference_storage_before was not migrated")
    }

    /// Writes legacy `repos` (without `current_sha`, with one row for the FK)
    /// and legacy `git_watcher_debug` (without `reference_storage_before`) via a
    /// raw connection, before any store touches the file.
    private func createLegacyDatabase(path: String, repositoryKey: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteStoreError.open("Could not create legacy test database")
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE repos (
            repo_key TEXT PRIMARY KEY NOT NULL,
            owner TEXT NOT NULL,
            name TEXT NOT NULL,
            source TEXT NOT NULL,
            local_path TEXT,
            pushed_at REAL,
            excluded INTEGER NOT NULL,
            accessible INTEGER NOT NULL
        );
        INSERT INTO repos(repo_key, owner, name, source, excluded, accessible)
            VALUES('\(repositoryKey)', 'owner', 'repo', 'local', 0, 1);
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

    private func assertColumnAbsent(_ column: String, table: String, path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteStoreError.open("Could not open legacy test database")
        }
        defer { sqlite3_close(database) }
        let present = try SQLiteSchema.hasColumn(column, table: table, database: database)
        XCTAssertFalse(present, "Expected legacy \(table) to lack \(column) before migration")
    }
}
