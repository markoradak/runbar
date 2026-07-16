import Foundation
import SQLite3

actor SQLiteGitHubStore: GitHubClientStoring, SQLiteBacked {
    let connection: SQLiteConnection
    private static let maximumDebugEntries = 100

    init(path: String) throws {
        connection = try SQLiteSupport.open(
            path: path,
            schema: """
                PRAGMA foreign_keys = ON;
                PRAGMA journal_mode = WAL;
                PRAGMA busy_timeout = 5000;
                CREATE TABLE IF NOT EXISTS etags (
                    canonical_url TEXT PRIMARY KEY NOT NULL,
                    etag TEXT NOT NULL,
                    body BLOB NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS github_request_debug (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp REAL NOT NULL,
                    sanitized_url TEXT NOT NULL,
                    status_code INTEGER,
                    cache_outcome TEXT NOT NULL,
                    rate_limit_remaining INTEGER,
                    rate_limit_reset REAL,
                    error_category TEXT
                );
                CREATE TABLE IF NOT EXISTS repo_preferences (
                    repo_key TEXT PRIMARY KEY NOT NULL,
                    excluded INTEGER NOT NULL DEFAULT 0,
                    accessible INTEGER NOT NULL DEFAULT 1
                );
                """
        )
    }

    static func production() throws -> SQLiteGitHubStore {
        try SQLiteGitHubStore(path: try SQLiteSupport.productionDatabasePath())
    }

    func cachedResponse(for canonicalURL: String) async throws -> GitHubCachedResponse? {
        let statement = try prepare(
            "SELECT etag, body FROM etags WHERE canonical_url = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bind(canonicalURL, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let etag = text(statement, column: 0)
        else { return nil }

        let byteCount = Int(sqlite3_column_bytes(statement, 1))
        let body: Data?
        if byteCount == 0 {
            body = Data()
        } else if let bytes = sqlite3_column_blob(statement, 1) {
            body = Data(bytes: bytes, count: byteCount)
        } else {
            body = nil
        }
        return GitHubCachedResponse(etag: etag, body: body)
    }

    func saveCachedResponse(_ response: GitHubCachedResponse, for canonicalURL: String) async throws {
        guard let body = response.body else { throw GitHubClientError.persistence }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare(
                """
                INSERT INTO etags(canonical_url, etag, body, updated_at) VALUES(?, ?, ?, ?)
                ON CONFLICT(canonical_url) DO UPDATE SET
                    etag = excluded.etag,
                    body = excluded.body,
                    updated_at = excluded.updated_at
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(canonicalURL, to: statement, index: 1)
            bind(response.etag, to: statement, index: 2)
            _ = body.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), SQLiteSupport.transient)
            }
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            try stepDone(statement)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func isRepositoryAccessible(_ repositoryKey: String) async throws -> Bool {
        let statement = try prepare(
            "SELECT accessible FROM repo_preferences WHERE repo_key = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bind(repositoryKey, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        return sqlite3_column_int(statement, 0) != 0
    }

    func markRepositoryInaccessible(_ repositoryKey: String) async throws -> Bool {
        let wasAccessible = try await isRepositoryAccessible(repositoryKey)
        guard wasAccessible else { return false }

        let statement = try prepare(
            """
            INSERT INTO repo_preferences(repo_key, excluded, accessible) VALUES(?, 0, 0)
            ON CONFLICT(repo_key) DO UPDATE SET accessible = 0
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(repositoryKey, to: statement, index: 1)
        try stepDone(statement)

        if try tableExists("repos") {
            let repository = try prepare("UPDATE repos SET accessible = 0 WHERE repo_key = ?")
            defer { sqlite3_finalize(repository) }
            bind(repositoryKey, to: repository, index: 1)
            try stepDone(repository)
        }
        return true
    }

    func setRepositoryAccessible(_ isAccessible: Bool, repositoryKey: String) async throws {
        let statement = try prepare(
            """
            INSERT INTO repo_preferences(repo_key, excluded, accessible) VALUES(?, 0, ?)
            ON CONFLICT(repo_key) DO UPDATE SET accessible = excluded.accessible
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(repositoryKey, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, isAccessible ? 1 : 0)
        try stepDone(statement)

        if try tableExists("repos") {
            let repository = try prepare("UPDATE repos SET accessible = ? WHERE repo_key = ?")
            defer { sqlite3_finalize(repository) }
            sqlite3_bind_int(repository, 1, isAccessible ? 1 : 0)
            bind(repositoryKey, to: repository, index: 2)
            try stepDone(repository)
        }
    }

    func appendDebugEntry(_ entry: GitHubDebugEntry) async throws {
        let statement = try prepare(
            """
            INSERT INTO github_request_debug(
                timestamp, sanitized_url, status_code, cache_outcome,
                rate_limit_remaining, rate_limit_reset, error_category
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, entry.timestamp.timeIntervalSince1970)
        bind(entry.sanitizedURL, to: statement, index: 2)
        if let statusCode = entry.statusCode { sqlite3_bind_int(statement, 3, Int32(statusCode)) }
        else { sqlite3_bind_null(statement, 3) }
        bind(entry.cacheOutcome.rawValue, to: statement, index: 4)
        if let remaining = entry.rateLimit.remaining { sqlite3_bind_int(statement, 5, Int32(remaining)) }
        else { sqlite3_bind_null(statement, 5) }
        if let resetAt = entry.rateLimit.resetAt {
            sqlite3_bind_double(statement, 6, resetAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        bindOptional(entry.errorCategory?.rawValue, to: statement, index: 7)
        try stepDone(statement)

        try execute(
            """
            DELETE FROM github_request_debug
            WHERE id NOT IN (
                SELECT id FROM github_request_debug ORDER BY id DESC LIMIT \(Self.maximumDebugEntries)
            )
            """
        )
    }

    func clearDebugEntries() async throws {
        try execute("DELETE FROM github_request_debug")
    }
}
