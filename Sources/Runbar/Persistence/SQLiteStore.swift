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

actor SQLiteStore: RepoDiscoveryStoring, SQLiteBacked {
    let connection: SQLiteConnection

    init(path: String) throws {
        connection = try SQLiteSupport.open(path: path)
    }

    static func production() throws -> SQLiteStore {
        try SQLiteStore(path: try SQLiteSupport.productionDatabasePath())
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
}
