import Foundation
import SQLite3

private final class GitHubSQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

actor SQLiteGitHubStore: GitHubClientStoring {
    private let connection: GitHubSQLiteConnection
    private var database: OpaquePointer { connection.handle }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let maximumDebugEntries = 100

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let handle { sqlite3_close(handle) }
            throw SQLiteStoreError.open(message)
        }

        do {
            try Self.execute(
                database: handle,
                sql: """
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
        } catch {
            sqlite3_close(handle)
            throw error
        }
        connection = GitHubSQLiteConnection(handle: handle)
    }

    static func production() throws -> SQLiteGitHubStore {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("Runbar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteGitHubStore(path: directory.appendingPathComponent("runbar.sqlite3").path)
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
                sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), Self.transient)
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

    private func tableExists(_ name: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bind(name, to: statement, index: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func execute(_ sql: String) throws {
        try Self.execute(database: database, sql: sql)
    }

    private static func execute(database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.statement(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteStoreError.statement(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.step(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bindOptional(_ value: String?, to statement: OpaquePointer, index: Int32) {
        if let value { bind(value, to: statement, index: index) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}
