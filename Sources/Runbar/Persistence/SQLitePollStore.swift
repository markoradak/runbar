import Foundation
import SQLite3

actor SQLitePollStore: WorkflowRunStoring, PollSchedulerRecording, SQLiteBacked {
    let connection: SQLiteConnection
    private static let maximumSchedulerEvents = 20_000

    init(path: String) throws {
        connection = try SQLiteSupport.open(
            path: path,
            schema: """
                PRAGMA foreign_keys = ON;
                PRAGMA journal_mode = WAL;
                PRAGMA busy_timeout = 5000;
                CREATE TABLE IF NOT EXISTS runs (
                    id INTEGER PRIMARY KEY NOT NULL,
                    repo_key TEXT NOT NULL,
                    workflow_id INTEGER NOT NULL,
                    workflow_name TEXT NOT NULL,
                    status TEXT NOT NULL,
                    conclusion TEXT,
                    run_started_at REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    head_branch TEXT,
                    head_sha TEXT NOT NULL,
                    event TEXT NOT NULL,
                    display_title TEXT NOT NULL,
                    html_url TEXT NOT NULL,
                    run_attempt INTEGER NOT NULL,
                    actor_login TEXT,
                    triggering_actor_login TEXT,
                    FOREIGN KEY (repo_key) REFERENCES repos(repo_key) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS runs_repo_updated_idx
                    ON runs(repo_key, updated_at DESC);
                CREATE INDEX IF NOT EXISTS runs_workflow_completed_idx
                    ON runs(workflow_id, status, updated_at DESC);
                CREATE TABLE IF NOT EXISTS scheduler_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    repository_count INTEGER NOT NULL,
                    total_poll_attempts INTEGER NOT NULL DEFAULT 0,
                    quota_consuming_requests INTEGER NOT NULL DEFAULT 0,
                    observed_active_run INTEGER NOT NULL DEFAULT 0,
                    latest_rate_limit_remaining INTEGER,
                    latest_rate_limit_reset REAL
                );
                CREATE TABLE IF NOT EXISTS scheduler_poll_debug (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER,
                    timestamp REAL NOT NULL,
                    repo_key TEXT NOT NULL,
                    trigger TEXT NOT NULL,
                    tier_before TEXT NOT NULL,
                    tier_after TEXT NOT NULL,
                    scheduled_interval REAL NOT NULL,
                    jitter_factor REAL NOT NULL,
                    status_code INTEGER,
                    cache_outcome TEXT NOT NULL,
                    rate_limit_remaining INTEGER,
                    rate_limit_reset REAL,
                    had_active_run INTEGER NOT NULL,
                    rate_limit_degraded INTEGER NOT NULL,
                    error_category TEXT,
                    FOREIGN KEY (session_id) REFERENCES scheduler_sessions(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS scheduler_poll_session_idx
                    ON scheduler_poll_debug(session_id, id);
                """
        )
    }

    static func production() throws -> SQLitePollStore {
        try SQLitePollStore(path: try SQLiteSupport.productionDatabasePath())
    }

    func saveWorkflowRuns(_ runs: [WorkflowRun], for repositoryKey: String) async throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for run in runs {
                guard run.repositoryKey == repositoryKey else { throw GitHubClientError.persistence }
                try upsert(run)
            }
            let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970
            let prune = try prepare("DELETE FROM runs WHERE created_at < ?")
            defer { sqlite3_finalize(prune) }
            sqlite3_bind_double(prune, 1, cutoff)
            try stepDone(prune)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func beginSchedulerSession(startedAt: Date, repositoryCount: Int) async throws -> Int64 {
        let statement = try prepare(
            "INSERT INTO scheduler_sessions(started_at, repository_count) VALUES(?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, startedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(repositoryCount))
        try stepDone(statement)
        return sqlite3_last_insert_rowid(database)
    }

    func updateSchedulerSession(_ sessionID: Int64, repositoryCount: Int) async throws {
        let statement = try prepare(
            "UPDATE scheduler_sessions SET repository_count = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(repositoryCount))
        sqlite3_bind_int64(statement, 2, sessionID)
        try stepDone(statement)
    }

    func recordSchedulerEvent(_ event: PollSchedulerEvent, sessionID: Int64?) async throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare(
                """
                INSERT INTO scheduler_poll_debug(
                    session_id, timestamp, repo_key, trigger, tier_before, tier_after,
                    scheduled_interval, jitter_factor, status_code, cache_outcome,
                    rate_limit_remaining, rate_limit_reset, had_active_run,
                    rate_limit_degraded, error_category
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }
            bindOptional(sessionID, to: statement, index: 1)
            sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
            bind(event.repositoryKey, to: statement, index: 3)
            bind(event.trigger.rawValue, to: statement, index: 4)
            bind(event.tierBefore.rawValue, to: statement, index: 5)
            bind(event.tierAfter.rawValue, to: statement, index: 6)
            sqlite3_bind_double(statement, 7, event.scheduledInterval)
            sqlite3_bind_double(statement, 8, event.jitterFactor)
            bindOptional(event.statusCode, to: statement, index: 9)
            bind(event.cacheOutcome.rawValue, to: statement, index: 10)
            bindOptional(event.rateLimit.remaining, to: statement, index: 11)
            bindOptional(event.rateLimit.resetAt?.timeIntervalSince1970, to: statement, index: 12)
            sqlite3_bind_int(statement, 13, event.hadActiveRun ? 1 : 0)
            sqlite3_bind_int(statement, 14, event.isRateLimitDegraded ? 1 : 0)
            bindOptional(event.errorCategory?.rawValue, to: statement, index: 15)
            try stepDone(statement)

            if let sessionID {
                let quotaIncrement = event.statusCode == 304 || event.statusCode == nil ? 0 : 1
                let session = try prepare(
                    """
                    UPDATE scheduler_sessions SET
                        total_poll_attempts = total_poll_attempts + 1,
                        quota_consuming_requests = quota_consuming_requests + ?,
                        observed_active_run = MAX(observed_active_run, ?),
                        latest_rate_limit_remaining = COALESCE(?, latest_rate_limit_remaining),
                        latest_rate_limit_reset = COALESCE(?, latest_rate_limit_reset)
                    WHERE id = ?
                    """
                )
                defer { sqlite3_finalize(session) }
                sqlite3_bind_int(session, 1, Int32(quotaIncrement))
                sqlite3_bind_int(session, 2, event.hadActiveRun ? 1 : 0)
                bindOptional(event.rateLimit.remaining, to: session, index: 3)
                bindOptional(event.rateLimit.resetAt?.timeIntervalSince1970, to: session, index: 4)
                sqlite3_bind_int64(session, 5, sessionID)
                try stepDone(session)
            }

            try execute(
                """
                DELETE FROM scheduler_poll_debug
                WHERE id NOT IN (
                    SELECT id FROM scheduler_poll_debug
                    ORDER BY id DESC LIMIT \(Self.maximumSchedulerEvents)
                )
                """
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func endSchedulerSession(_ sessionID: Int64, endedAt: Date) async throws {
        let statement = try prepare(
            "UPDATE scheduler_sessions SET ended_at = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, endedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, sessionID)
        try stepDone(statement)
    }

    private func upsert(_ run: WorkflowRun) throws {
        let statement = try prepare(
            """
            INSERT INTO runs(
                id, repo_key, workflow_id, workflow_name, status, conclusion,
                run_started_at, created_at, updated_at, head_branch, head_sha,
                event, display_title, html_url, run_attempt, actor_login,
                triggering_actor_login
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                repo_key = excluded.repo_key,
                workflow_id = excluded.workflow_id,
                workflow_name = excluded.workflow_name,
                status = excluded.status,
                conclusion = excluded.conclusion,
                run_started_at = excluded.run_started_at,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                head_branch = excluded.head_branch,
                head_sha = excluded.head_sha,
                event = excluded.event,
                display_title = excluded.display_title,
                html_url = excluded.html_url,
                run_attempt = excluded.run_attempt,
                actor_login = excluded.actor_login,
                triggering_actor_login = excluded.triggering_actor_login
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, run.id)
        bind(run.repositoryKey, to: statement, index: 2)
        sqlite3_bind_int64(statement, 3, run.workflowID)
        bind(run.workflowName, to: statement, index: 4)
        bind(run.status, to: statement, index: 5)
        bindOptional(run.conclusion, to: statement, index: 6)
        bindOptional(run.runStartedAt?.timeIntervalSince1970, to: statement, index: 7)
        sqlite3_bind_double(statement, 8, run.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, run.updatedAt.timeIntervalSince1970)
        bindOptional(run.headBranch, to: statement, index: 10)
        bind(run.headSHA, to: statement, index: 11)
        bind(run.event, to: statement, index: 12)
        bind(run.displayTitle, to: statement, index: 13)
        bind(run.htmlURL, to: statement, index: 14)
        sqlite3_bind_int(statement, 15, Int32(run.runAttempt))
        bindOptional(run.actorLogin, to: statement, index: 16)
        bindOptional(run.triggeringActorLogin, to: statement, index: 17)
        try stepDone(statement)
    }

}
