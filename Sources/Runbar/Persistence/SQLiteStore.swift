import Foundation
import SQLite3

enum SQLiteStoreError: Error, CustomStringConvertible {
    case open(String)
    case statement(String)
    case step(String)

    var description: String {
        switch self {
        case let .open(message), let .statement(message), let .step(message): message
        }
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

actor SQLiteStore: RepoDiscoveryStoring {
    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.handle }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &connection, flags, nil) == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let connection { sqlite3_close(connection) }
            throw SQLiteStoreError.open(message)
        }
        do {
            try Self.execute(
                database: connection,
                sql: """
                PRAGMA foreign_keys = ON;
                PRAGMA journal_mode = WAL;
                PRAGMA busy_timeout = 5000;
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS repo_preferences (
                    repo_key TEXT PRIMARY KEY NOT NULL,
                    excluded INTEGER NOT NULL DEFAULT 0,
                    accessible INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE IF NOT EXISTS repos (
                    repo_key TEXT PRIMARY KEY NOT NULL,
                    owner TEXT NOT NULL,
                    name TEXT NOT NULL,
                    source TEXT NOT NULL,
                    local_path TEXT,
                    pushed_at REAL,
                    excluded INTEGER NOT NULL,
                    accessible INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS workflows (
                    repo_key TEXT NOT NULL,
                    file_name TEXT NOT NULL,
                    name TEXT NOT NULL,
                    events_json TEXT NOT NULL,
                    PRIMARY KEY (repo_key, file_name),
                    FOREIGN KEY (repo_key) REFERENCES repos(repo_key) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS scan_skips (
                    relative_path TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    PRIMARY KEY (relative_path, reason)
                );
                """
            )
        } catch {
            sqlite3_close(connection)
            throw error
        }
        self.connection = SQLiteConnection(handle: connection)
    }

    static func production() throws -> SQLiteStore {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("Runbar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStore(path: directory.appendingPathComponent("runbar.sqlite3").path)
    }

    func codeRootPath() async throws -> String? {
        let statement = try prepare("SELECT value FROM settings WHERE key = 'code_root' LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, column: 0)
    }

    func setCodeRootPath(_ path: String) async throws {
        let statement = try prepare(
            "INSERT INTO settings(key, value) VALUES('code_root', ?) " +
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        )
        defer { sqlite3_finalize(statement) }
        bind(path, to: statement, index: 1)
        try stepDone(statement)
    }

    func repositoryPreferences() async throws -> [String: RepositoryPreference] {
        let statement = try prepare("SELECT repo_key, excluded, accessible FROM repo_preferences")
        defer { sqlite3_finalize(statement) }
        var result: [String: RepositoryPreference] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = text(statement, column: 0) else { continue }
            result[key] = RepositoryPreference(
                isExcluded: sqlite3_column_int(statement, 1) != 0,
                isAccessible: sqlite3_column_int(statement, 2) != 0
            )
        }
        return result
    }

    func setExcluded(_ isExcluded: Bool, repositoryKey: String) async throws {
        let statement = try prepare(
            """
            INSERT INTO repo_preferences(repo_key, excluded, accessible)
            VALUES(?, ?, COALESCE((SELECT accessible FROM repo_preferences WHERE repo_key = ?), 1))
            ON CONFLICT(repo_key) DO UPDATE SET excluded = excluded.excluded
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(repositoryKey, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, isExcluded ? 1 : 0)
        bind(repositoryKey, to: statement, index: 3)
        try stepDone(statement)

        let snapshot = try prepare("UPDATE repos SET excluded = ? WHERE repo_key = ?")
        defer { sqlite3_finalize(snapshot) }
        sqlite3_bind_int(snapshot, 1, isExcluded ? 1 : 0)
        bind(repositoryKey, to: snapshot, index: 2)
        try stepDone(snapshot)
    }

    func setAccessible(_ isAccessible: Bool, repositoryKey: String) async throws {
        let statement = try prepare(
            """
            INSERT INTO repo_preferences(repo_key, excluded, accessible)
            VALUES(?, COALESCE((SELECT excluded FROM repo_preferences WHERE repo_key = ?), 0), ?)
            ON CONFLICT(repo_key) DO UPDATE SET accessible = excluded.accessible
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(repositoryKey, to: statement, index: 1)
        bind(repositoryKey, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, isAccessible ? 1 : 0)
        try stepDone(statement)

        let snapshot = try prepare("UPDATE repos SET accessible = ? WHERE repo_key = ?")
        defer { sqlite3_finalize(snapshot) }
        sqlite3_bind_int(snapshot, 1, isAccessible ? 1 : 0)
        bind(repositoryKey, to: snapshot, index: 2)
        try stepDone(snapshot)
    }

    func saveDiscoverySnapshot(_ snapshot: RepoDiscoverySnapshot) async throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let existingRepositoryKeys = try repositoryKeys()
            try execute("DELETE FROM workflows")
            try execute("DELETE FROM scan_skips")

            for repository in snapshot.repositories {
                try upsert(repository: repository)
                for workflow in repository.workflows {
                    try insert(workflow: workflow, repositoryKey: repository.id)
                }
            }
            let retainedRepositoryKeys = Set(snapshot.repositories.map(\.id))
            for repositoryKey in existingRepositoryKeys.subtracting(retainedRepositoryKeys) {
                try deleteRepository(repositoryKey)
            }
            for skipped in snapshot.skippedLocalRepositories {
                try insert(skipped: skipped)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func upsert(repository: DiscoveredRepository) throws {
        let statement = try prepare(
            """
            INSERT INTO repos(repo_key, owner, name, source, local_path, pushed_at, excluded, accessible)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(repo_key) DO UPDATE SET
                owner = excluded.owner,
                name = excluded.name,
                source = excluded.source,
                local_path = excluded.local_path,
                pushed_at = excluded.pushed_at,
                excluded = excluded.excluded,
                accessible = excluded.accessible
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(repository.id, to: statement, index: 1)
        bind(repository.identity.owner, to: statement, index: 2)
        bind(repository.identity.name, to: statement, index: 3)
        bind(repository.source.rawValue, to: statement, index: 4)
        bindOptional(repository.localPath, to: statement, index: 5)
        if let pushedAt = repository.pushedAt {
            sqlite3_bind_double(statement, 6, pushedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_int(statement, 7, repository.isExcluded ? 1 : 0)
        sqlite3_bind_int(statement, 8, repository.isAccessible ? 1 : 0)
        try stepDone(statement)

        let preference = try prepare(
            """
            INSERT INTO repo_preferences(repo_key, excluded, accessible) VALUES(?, ?, ?)
            ON CONFLICT(repo_key) DO NOTHING
            """
        )
        defer { sqlite3_finalize(preference) }
        bind(repository.id, to: preference, index: 1)
        sqlite3_bind_int(preference, 2, repository.isExcluded ? 1 : 0)
        sqlite3_bind_int(preference, 3, repository.isAccessible ? 1 : 0)
        try stepDone(preference)
    }

    private func repositoryKeys() throws -> Set<String> {
        let statement = try prepare("SELECT repo_key FROM repos")
        defer { sqlite3_finalize(statement) }
        var keys: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let key = text(statement, column: 0) { keys.insert(key) }
        }
        return keys
    }

    private func deleteRepository(_ repositoryKey: String) throws {
        let statement = try prepare("DELETE FROM repos WHERE repo_key = ?")
        defer { sqlite3_finalize(statement) }
        bind(repositoryKey, to: statement, index: 1)
        try stepDone(statement)
    }

    private func insert(workflow: WorkflowMetadata, repositoryKey: String) throws {
        let statement = try prepare(
            "INSERT INTO workflows(repo_key, file_name, name, events_json) VALUES(?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        let events = try JSONEncoder().encode(workflow.events)
        bind(repositoryKey, to: statement, index: 1)
        bind(workflow.fileName, to: statement, index: 2)
        bind(workflow.name, to: statement, index: 3)
        bind(String(decoding: events, as: UTF8.self), to: statement, index: 4)
        try stepDone(statement)
    }

    private func insert(skipped: SkippedLocalRepository) throws {
        let statement = try prepare("INSERT INTO scan_skips(relative_path, reason) VALUES(?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(skipped.relativePath, to: statement, index: 1)
        bind(skipped.reason.rawValue, to: statement, index: 2)
        try stepDone(statement)
    }

    private func execute(_ sql: String) throws {
        try Self.execute(database: database, sql: sql)
    }

    private static func execute(database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.statement(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
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
