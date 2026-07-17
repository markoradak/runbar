import Foundation
import SQLite3

/// The single owner of the on-disk schema.
///
/// Every store opens its own connection to the same `runbar.sqlite3`, and every
/// connection applies **this whole schema** on open. Because it is complete and
/// idempotent (`IF NOT EXISTS` throughout, guarded `ALTER`s), it does not matter
/// which store opens first — whoever gets there creates everything, in dependency
/// order, and the rest are no-ops. That removes the construction-order race that
/// used to require `tableExists` guards and a store `ALTER`ing another store's
/// table.
///
/// Tables are ordered parent-before-child so foreign keys resolve cleanly:
/// `repos` and `runs` before the debug tables that reference them.
enum SQLiteSchema {
    static func migrate(_ database: OpaquePointer) throws {
        try SQLiteSupport.execute(database: database, sql: schema)
        try runColumnMigrations(database)
    }

    private static let schema = """
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
            accessible INTEGER NOT NULL,
            current_sha TEXT
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

        CREATE TABLE IF NOT EXISTS menu_timer_debug (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            run_id INTEGER NOT NULL,
            elapsed_seconds INTEGER NOT NULL,
            source TEXT NOT NULL,
            FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS menu_timer_timestamp_idx
            ON menu_timer_debug(timestamp DESC);

        CREATE TABLE IF NOT EXISTS git_watcher_debug (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repo_key TEXT NOT NULL,
            signal TEXT NOT NULL,
            reference_storage_before TEXT NOT NULL DEFAULT 'none',
            detected_at REAL NOT NULL,
            poll_started_at REAL,
            latency_ms INTEGER,
            current_sha TEXT,
            FOREIGN KEY (repo_key) REFERENCES repos(repo_key) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS git_watcher_detected_idx
            ON git_watcher_debug(detected_at DESC);

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

    /// Additive columns added to tables that predate them. Each is guarded so a
    /// fresh database (which already has the column from the `CREATE` above) and
    /// an older one both converge on the same shape. Idempotent — safe to run on
    /// every open.
    private static func runColumnMigrations(_ database: OpaquePointer) throws {
        let additions: [(table: String, column: String, ddl: String)] = [
            ("repos", "current_sha",
             "ALTER TABLE repos ADD COLUMN current_sha TEXT"),
            ("git_watcher_debug", "reference_storage_before",
             "ALTER TABLE git_watcher_debug ADD COLUMN reference_storage_before TEXT NOT NULL DEFAULT 'none'"),
            ("provider_runs", "preview_url",
             "ALTER TABLE provider_runs ADD COLUMN preview_url TEXT"),
        ]
        for addition in additions where try !hasColumn(addition.column, table: addition.table, database: database) {
            try SQLiteSupport.execute(database: database, sql: addition.ddl)
        }
    }

    static func hasColumn(_ column: String, table: String, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw SQLiteStoreError.statement(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: pointer) == column { return true }
        }
        return false
    }
}
