import Foundation
import SQLite3

actor SQLiteProviderStore: ProviderExecutionStoring, SQLiteBacked {
    let connection: SQLiteConnection

    init(path: String) throws {
        connection = try SQLiteSupport.open(path: path, schema: Self.schema) { database in
            Self.migrateAddingColumn(database: database, sql: "ALTER TABLE provider_runs ADD COLUMN preview_url TEXT")
        }
    }

    /// Additive column migration — a duplicate-column failure means the
    /// column already exists (fresh schema or a previous run), which is fine.
    private static func migrateAddingColumn(database: OpaquePointer, sql: String) {
        try? SQLiteSupport.execute(database: database, sql: sql)
    }

    static func production() throws -> SQLiteProviderStore {
        try SQLiteProviderStore(path: try SQLiteSupport.productionDatabasePath())
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
}
