import Foundation
import SQLite3

actor SQLiteProviderStore: ProviderExecutionStoring, SQLiteBacked {
    let connection: SQLiteConnection

    init(path: String) throws {
        connection = try SQLiteSupport.open(path: path)
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

            // Drop any zero-duration cancelled deployments already stored for
            // this provider. VercelClient now filters these at ingest (a build
            // Vercel auto-skipped for "no changes", which it hides from its own
            // dashboard), but rows persisted by an earlier build would otherwise
            // linger until the 30-day prune — so clear them on the next refresh.
            let dropSkipped = try prepare(
                """
                DELETE FROM provider_runs
                WHERE provider = ? AND conclusion = 'cancelled'
                  AND run_started_at = created_at AND updated_at = created_at
                """
            )
            defer { sqlite3_finalize(dropSkipped) }
            bind(provider.rawValue, to: dropSkipped, index: 1)
            try stepDone(dropSkipped)

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
}
