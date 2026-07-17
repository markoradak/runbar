import Foundation
import SQLite3

struct GitWatcherDebugEntry: Equatable, Sendable {
    let repositoryKey: String
    let signal: GitReferenceSignal
    let referenceStorageBefore: GitReferenceStorage
    let detectedAt: Date
    let pollStartedAt: Date?
    let latencyMilliseconds: Int?
    let currentSHA: String?
}

actor SQLiteGitWatcherStore: GitWatcherRecording, SQLiteBacked {
    let connection: SQLiteConnection
    private static let maximumEvents = 2_000

    init(path: String) throws {
        connection = try SQLiteSupport.open(path: path)
    }

    static func production() throws -> SQLiteGitWatcherStore {
        try SQLiteGitWatcherStore(path: try SQLiteSupport.productionDatabasePath())
    }

    func updateCurrentSHA(_ sha: String?, repositoryKey: String) async throws {
        let statement = try prepare("UPDATE repos SET current_sha = ? WHERE repo_key = ?")
        defer { sqlite3_finalize(statement) }
        bindOptional(sha, to: statement, index: 1)
        bind(repositoryKey, to: statement, index: 2)
        try stepDone(statement)
    }

    func recordGitWatcherEvent(_ event: GitWatcherEvent) async throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare(
                """
                INSERT INTO git_watcher_debug(
                    repo_key, signal, reference_storage_before, detected_at, poll_started_at, latency_ms, current_sha
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(event.repositoryKey, to: statement, index: 1)
            bind(event.signal.rawValue, to: statement, index: 2)
            bind(event.referenceStorageBefore.rawValue, to: statement, index: 3)
            sqlite3_bind_double(statement, 4, event.detectedAt.timeIntervalSince1970)
            bindOptional(event.pollStartedAt?.timeIntervalSince1970, to: statement, index: 5)
            bindOptional(event.latencyMilliseconds, to: statement, index: 6)
            bindOptional(event.currentSHA, to: statement, index: 7)
            try stepDone(statement)

            try execute(
                """
                DELETE FROM git_watcher_debug
                WHERE id NOT IN (
                    SELECT id FROM git_watcher_debug ORDER BY id DESC LIMIT \(Self.maximumEvents)
                )
                """
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func currentSHA(repositoryKey: String) async throws -> String? {
        let statement = try prepare("SELECT current_sha FROM repos WHERE repo_key = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(repositoryKey, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, column: 0)
    }

    func debugEntries() async throws -> [GitWatcherDebugEntry] {
        let statement = try prepare(
            """
            SELECT repo_key, signal, reference_storage_before, detected_at, poll_started_at, latency_ms, current_sha
            FROM git_watcher_debug ORDER BY id ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        var entries: [GitWatcherDebugEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let repositoryKey = text(statement, column: 0),
                  let signalRaw = text(statement, column: 1),
                  let signal = GitReferenceSignal(rawValue: signalRaw),
                  let storageRaw = text(statement, column: 2),
                  let referenceStorage = GitReferenceStorage(rawValue: storageRaw)
            else { continue }
            let pollStartedAt = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let latency = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int(statement, 5))
            entries.append(
                GitWatcherDebugEntry(
                    repositoryKey: repositoryKey,
                    signal: signal,
                    referenceStorageBefore: referenceStorage,
                    detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    pollStartedAt: pollStartedAt,
                    latencyMilliseconds: latency,
                    currentSHA: text(statement, column: 6)
                )
            )
        }
        return entries
    }
}
