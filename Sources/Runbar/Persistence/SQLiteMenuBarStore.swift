import Foundation
import SQLite3

actor SQLiteMenuBarStore: MenuBarDataStoring, SQLiteBacked {
    let connection: SQLiteConnection
    private static let maximumTimerTicks = 3_600

    init(path: String) throws {
        connection = try SQLiteSupport.open(
            path: path,
            schema: """
                PRAGMA foreign_keys = ON;
                PRAGMA journal_mode = WAL;
                PRAGMA busy_timeout = 5000;
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
                \(SQLiteProviderStore.schema)
                """
        )
    }

    static func production() throws -> SQLiteMenuBarStore {
        try SQLiteMenuBarStore(path: try SQLiteSupport.productionDatabasePath())
    }

    func loadMenuBarRuns(recentLimit: Int = 20) async throws -> MenuBarRunSnapshot {
        let hasGitHubRunStorage = try tableExists("runs")
        let githubRunning = hasGitHubRunStorage
            ? try loadRuns(
                whereClause: "r.status IN ('queued', 'in_progress')",
                orderClause: "COALESCE(r.run_started_at, r.created_at) DESC, r.id DESC",
                limit: nil
            )
            : []
        let githubRecent = hasGitHubRunStorage
            ? try loadRuns(
                whereClause: "r.status = 'completed'",
                orderClause: "r.created_at DESC, r.id DESC",
                limit: max(0, recentLimit)
            )
            : []
        let providerRunning = try loadProviderRuns(active: true, limit: nil)
        let providerRecent = try loadProviderRuns(active: false, limit: max(0, recentLimit))
        let running = (githubRunning + providerRunning).sorted {
            let lhs = $0.run.runStartedAt ?? $0.run.createdAt
            let rhs = $1.run.runStartedAt ?? $1.run.createdAt
            if lhs == rhs { return $0.id > $1.id }
            return lhs > rhs
        }
        let recent = (githubRecent + providerRecent)
            .sorted {
                if $0.run.createdAt == $1.run.createdAt { return $0.id > $1.id }
                return $0.run.createdAt > $1.run.createdAt
            }
            .prefix(max(0, recentLimit))
        return MenuBarRunSnapshot(running: running, recent: Array(recent))
    }

    func recordMenuBarTimerTick(_ tick: MenuBarTimerTick) async throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare(
                "INSERT INTO menu_timer_debug(timestamp, run_id, elapsed_seconds, source) VALUES(?, ?, ?, ?)"
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, tick.timestamp.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 2, tick.runID)
            sqlite3_bind_int(statement, 3, Int32(tick.elapsedSeconds))
            bind(tick.source, to: statement, index: 4)
            try stepDone(statement)
            try execute(
                """
                DELETE FROM menu_timer_debug
                WHERE id NOT IN (
                    SELECT id FROM menu_timer_debug ORDER BY id DESC LIMIT \(Self.maximumTimerTicks)
                )
                """
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func timerTicks() async throws -> [MenuBarTimerTick] {
        let statement = try prepare(
            "SELECT timestamp, run_id, elapsed_seconds, source FROM menu_timer_debug ORDER BY id ASC"
        )
        defer { sqlite3_finalize(statement) }
        var ticks: [MenuBarTimerTick] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let source = text(statement, column: 3) else { continue }
            ticks.append(
                MenuBarTimerTick(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    runID: sqlite3_column_int64(statement, 1),
                    elapsedSeconds: Int(sqlite3_column_int(statement, 2)),
                    source: source
                )
            )
        }
        return ticks
    }

    private func loadRuns(
        whereClause: String,
        orderClause: String,
        limit: Int?
    ) throws -> [MenuBarRun] {
        let limitClause = limit.map { " LIMIT \($0)" } ?? ""
        let statement = try prepare(
            """
            SELECT
                r.id, r.repo_key, r.workflow_id, r.workflow_name, r.status, r.conclusion,
                r.run_started_at, r.created_at, r.updated_at, r.head_branch, r.head_sha,
                r.event, r.display_title, r.html_url, r.run_attempt, r.actor_login,
                r.triggering_actor_login, p.owner, p.name,
                CASE WHEN p.current_sha IS NOT NULL AND lower(p.current_sha) = lower(r.head_sha)
                     THEN 1 ELSE 0 END
            FROM runs r
            JOIN repos p ON p.repo_key = r.repo_key
            WHERE p.excluded = 0 AND p.accessible = 1 AND \(whereClause)
            ORDER BY \(orderClause)\(limitClause)
            """
        )
        defer { sqlite3_finalize(statement) }
        var rows: [MenuBarRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let repositoryKey = text(statement, column: 1),
                  let workflowName = text(statement, column: 3),
                  let status = text(statement, column: 4),
                  let headSHA = text(statement, column: 10),
                  let event = text(statement, column: 11),
                  let displayTitle = text(statement, column: 12),
                  let htmlURL = text(statement, column: 13),
                  let owner = text(statement, column: 17),
                  let name = text(statement, column: 18)
            else { continue }
            let workflowID = sqlite3_column_int64(statement, 2)
            let medianDurationSeconds = status == "queued" || status == "in_progress"
                ? try loadMedianDurationSeconds(repositoryKey: repositoryKey, workflowID: workflowID)
                : nil
            rows.append(
                MenuBarRun(
                    run: WorkflowRun(
                        id: sqlite3_column_int64(statement, 0),
                        repositoryKey: repositoryKey,
                        workflowID: workflowID,
                        workflowName: workflowName,
                        status: status,
                        conclusion: text(statement, column: 5),
                        runStartedAt: date(statement, column: 6),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                        headBranch: text(statement, column: 9),
                        headSHA: headSHA,
                        event: event,
                        displayTitle: displayTitle,
                        htmlURL: htmlURL,
                        runAttempt: Int(sqlite3_column_int(statement, 14)),
                        actorLogin: text(statement, column: 15),
                        triggeringActorLogin: text(statement, column: 16)
                    ),
                    repository: RepoIdentity(owner: owner, name: name),
                    matchesLocalHEAD: sqlite3_column_int(statement, 19) != 0,
                    medianDurationSeconds: medianDurationSeconds
                )
            )
        }
        return rows
    }

    private func loadMedianDurationSeconds(
        repositoryKey: String,
        workflowID: Int64
    ) throws -> Int? {
        let statement = try prepare(
            """
            SELECT r.updated_at - r.run_started_at
            FROM runs r
            WHERE r.repo_key = ?
              AND r.workflow_id = ?
              AND r.status = 'completed'
              AND r.run_started_at IS NOT NULL
              AND r.updated_at > r.run_started_at
            ORDER BY r.updated_at DESC, r.id DESC
            LIMIT 10
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(repositoryKey, to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, workflowID)
        var durations: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            durations.append(Int(sqlite3_column_double(statement, 0).rounded()))
        }
        guard !durations.isEmpty else { return nil }
        durations.sort()
        let middle = durations.count / 2
        if durations.count.isMultiple(of: 2) {
            return (durations[middle - 1] + durations[middle]) / 2
        }
        return durations[middle]
    }

    private func loadProviderRuns(active: Bool, limit: Int?) throws -> [MenuBarRun] {
        let statusClause = active
            ? "pr.status IN ('queued', 'in_progress')"
            : "pr.status = 'completed'"
        let orderClause = active
            ? "COALESCE(pr.run_started_at, pr.created_at) DESC, pr.synthetic_id DESC"
            : "pr.created_at DESC, pr.synthetic_id DESC"
        let limitClause = limit.map { " LIMIT \($0)" } ?? ""
        let statement = try prepare(
            """
            SELECT
                pr.synthetic_id, pr.provider, pr.external_id, pr.repo_key,
                pr.owner, pr.repo_name, pr.workflow_id, pr.project_key,
                pr.project_name, pr.status, pr.conclusion, pr.run_started_at,
                pr.created_at, pr.updated_at, pr.head_branch, pr.head_sha,
                pr.environment, pr.display_title, pr.web_url,
                CASE WHEN p.current_sha IS NOT NULL AND pr.head_sha != ''
                          AND lower(p.current_sha) = lower(pr.head_sha)
                     THEN 1 ELSE 0 END,
                pr.preview_url
            FROM provider_runs pr
            LEFT JOIN repos p ON p.repo_key = pr.repo_key
            WHERE \(statusClause)
            ORDER BY \(orderClause)\(limitClause)
            """
        )
        defer { sqlite3_finalize(statement) }
        var rows: [MenuBarRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let providerValue = text(statement, column: 1),
                  let provider = ExecutionProvider(rawValue: providerValue),
                  let externalID = text(statement, column: 2),
                  let repositoryKey = text(statement, column: 3),
                  let owner = text(statement, column: 4),
                  let name = text(statement, column: 5),
                  let projectKey = text(statement, column: 7),
                  let projectName = text(statement, column: 8),
                  let status = text(statement, column: 9),
                  let headSHA = text(statement, column: 15),
                  let environment = text(statement, column: 16),
                  let displayTitle = text(statement, column: 17),
                  let webURL = text(statement, column: 18)
            else { continue }
            let workflowID = sqlite3_column_int64(statement, 6)
            let median = active
                ? try loadProviderMedianDurationSeconds(provider: provider, workflowID: workflowID)
                : nil
            rows.append(
                MenuBarRun(
                    run: WorkflowRun(
                        id: sqlite3_column_int64(statement, 0),
                        repositoryKey: repositoryKey,
                        workflowID: workflowID,
                        workflowName: projectName,
                        status: status,
                        conclusion: text(statement, column: 10),
                        runStartedAt: date(statement, column: 11),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
                        headBranch: text(statement, column: 14),
                        headSHA: headSHA,
                        event: environment,
                        displayTitle: displayTitle,
                        htmlURL: webURL,
                        runAttempt: 1,
                        actorLogin: nil,
                        triggeringActorLogin: nil,
                        provider: provider,
                        externalID: externalID,
                        previewURL: text(statement, column: 20),
                        projectKey: projectKey
                    ),
                    repository: RepoIdentity(owner: owner, name: name),
                    matchesLocalHEAD: sqlite3_column_int(statement, 19) != 0,
                    medianDurationSeconds: median
                )
            )
        }
        return rows
    }

    private func loadProviderMedianDurationSeconds(
        provider: ExecutionProvider,
        workflowID: Int64
    ) throws -> Int? {
        let statement = try prepare(
            """
            SELECT updated_at - run_started_at
            FROM provider_runs
            WHERE provider = ? AND workflow_id = ? AND status = 'completed'
              AND run_started_at IS NOT NULL AND updated_at > run_started_at
            ORDER BY updated_at DESC, synthetic_id DESC
            LIMIT 10
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, workflowID)
        var durations: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            durations.append(Int(sqlite3_column_double(statement, 0).rounded()))
        }
        guard !durations.isEmpty else { return nil }
        durations.sort()
        let middle = durations.count / 2
        if durations.count.isMultiple(of: 2) {
            return (durations[middle - 1] + durations[middle]) / 2
        }
        return durations[middle]
    }
}
