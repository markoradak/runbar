import Foundation
import SQLite3

private final class ProviderSQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close(handle) }
}

actor SQLiteProviderStore: ProviderExecutionStoring {
    private let connection: ProviderSQLiteConnection
    private var database: OpaquePointer { connection.handle }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let handle { sqlite3_close(handle) }
            throw SQLiteStoreError.open(message)
        }
        do {
            try Self.execute(database: handle, sql: Self.schema)
            Self.migrateAddingColumn(database: handle, sql: "ALTER TABLE provider_runs ADD COLUMN preview_url TEXT")
        } catch {
            sqlite3_close(handle)
            throw error
        }
        connection = ProviderSQLiteConnection(handle: handle)
    }

    /// Additive column migration — a duplicate-column failure means the
    /// column already exists (fresh schema or a previous run), which is fine.
    private static func migrateAddingColumn(database: OpaquePointer, sql: String) {
        try? execute(database: database, sql: sql)
    }

    static func production() throws -> SQLiteProviderStore {
        try SQLiteProviderStore(path: try productionDatabasePath())
    }

    func saveProviderExecutions(
        _ executions: [ProviderExecution],
        provider: ExecutionProvider
    ) async throws {
        guard executions.allSatisfy({ $0.provider == provider }) else {
            throw ProviderClientError.persistence
        }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for execution in executions { try upsert(execution) }
            let prune = try prepare("DELETE FROM provider_runs WHERE created_at < ?")
            defer { sqlite3_finalize(prune) }
            sqlite3_bind_double(
                prune,
                1,
                Date().addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970
            )
            try stepDone(prune)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func deleteProviderExecutions(provider: ExecutionProvider) async throws {
        let statement = try prepare("DELETE FROM provider_runs WHERE provider = ?")
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: statement, index: 1)
        try stepDone(statement)
    }

    private func upsert(_ item: ProviderExecution) throws {
        let run = item.workflowRun
        let statement = try prepare(
            """
            INSERT INTO provider_runs(
                synthetic_id, provider, external_id, repo_key, owner, repo_name,
                workflow_id, project_key, project_name, status, conclusion,
                run_started_at, created_at, updated_at, head_branch, head_sha,
                environment, display_title, web_url, preview_url
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, external_id) DO UPDATE SET
                synthetic_id = excluded.synthetic_id,
                repo_key = excluded.repo_key,
                owner = excluded.owner,
                repo_name = excluded.repo_name,
                workflow_id = excluded.workflow_id,
                project_key = excluded.project_key,
                project_name = excluded.project_name,
                status = excluded.status,
                conclusion = excluded.conclusion,
                run_started_at = excluded.run_started_at,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                head_branch = excluded.head_branch,
                head_sha = excluded.head_sha,
                environment = excluded.environment,
                display_title = excluded.display_title,
                web_url = excluded.web_url,
                preview_url = excluded.preview_url
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, run.id)
        bind(item.provider.rawValue, to: statement, index: 2)
        bind(item.externalID, to: statement, index: 3)
        bind(item.repositoryKey, to: statement, index: 4)
        bind(item.repository.owner, to: statement, index: 5)
        bind(item.repository.name, to: statement, index: 6)
        sqlite3_bind_int64(statement, 7, item.workflowID)
        bind(item.projectKey, to: statement, index: 8)
        bind(item.projectName, to: statement, index: 9)
        bind(item.status, to: statement, index: 10)
        bindOptional(item.conclusion, to: statement, index: 11)
        bindOptional(item.startedAt?.timeIntervalSince1970, to: statement, index: 12)
        sqlite3_bind_double(statement, 13, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 14, item.updatedAt.timeIntervalSince1970)
        bindOptional(item.headBranch, to: statement, index: 15)
        bind(item.headSHA, to: statement, index: 16)
        bind(item.environment, to: statement, index: 17)
        bind(item.displayTitle, to: statement, index: 18)
        bind(item.webURL, to: statement, index: 19)
        bindOptional(item.previewURL, to: statement, index: 20)
        try stepDone(statement)
    }

    static let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA busy_timeout = 5000;
        CREATE TABLE IF NOT EXISTS provider_runs (
            synthetic_id INTEGER NOT NULL,
            provider TEXT NOT NULL,
            external_id TEXT NOT NULL,
            repo_key TEXT NOT NULL,
            owner TEXT NOT NULL,
            repo_name TEXT NOT NULL,
            workflow_id INTEGER NOT NULL,
            project_key TEXT NOT NULL,
            project_name TEXT NOT NULL,
            status TEXT NOT NULL,
            conclusion TEXT,
            run_started_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            head_branch TEXT,
            head_sha TEXT NOT NULL,
            environment TEXT NOT NULL,
            display_title TEXT NOT NULL,
            web_url TEXT NOT NULL,
            preview_url TEXT,
            PRIMARY KEY(provider, external_id)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS provider_runs_synthetic_id_idx
            ON provider_runs(synthetic_id);
        CREATE INDEX IF NOT EXISTS provider_runs_status_updated_idx
            ON provider_runs(status, updated_at DESC);
        CREATE INDEX IF NOT EXISTS provider_runs_workflow_completed_idx
            ON provider_runs(provider, workflow_id, status, updated_at DESC);
        """

    private static func productionDatabasePath() throws -> String {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("Runbar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("runbar.sqlite3").path
    }

    private func execute(_ sql: String) throws { try Self.execute(database: database, sql: sql) }

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
        else { throw SQLiteStoreError.statement(String(cString: sqlite3_errmsg(database))) }
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

    private func bindOptional(_ value: TimeInterval?, to statement: OpaquePointer, index: Int32) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }
}
