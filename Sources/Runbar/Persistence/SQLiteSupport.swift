import Foundation
import SQLite3

/// Owns an open sqlite3 handle and closes it exactly once, when the last
/// reference goes away.
final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

/// Raw-sqlite3 plumbing shared by every store. The statics take a `database`
/// explicitly because a store's `init` needs them to run its schema before it
/// has a `SQLiteConnection` to hand.
enum SQLiteSupport {
    /// `SQLITE_TRANSIENT` — tells sqlite3 to copy the bound bytes rather than
    /// retain the caller's pointer.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens `path` and applies the full canonical schema (`SQLiteSchema`),
    /// closing the handle again if that fails — so a half-initialised store never
    /// escapes. Every store opens the same way, so schema creation no longer
    /// depends on which store opens first.
    static func open(path: String) throws -> SQLiteConnection {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let handle { sqlite3_close(handle) }
            throw SQLiteStoreError.open(message)
        }
        do {
            try SQLiteSchema.migrate(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        return SQLiteConnection(handle: handle)
    }

    static func execute(database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.statement(message)
        }
    }

    /// The one on-disk database every store opens.
    static func productionDatabasePath() throws -> String {
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
}

/// Supplies the statement helpers to any store that holds a connection, so a
/// store's own code is only its schema and its queries.
protocol SQLiteBacked {
    var connection: SQLiteConnection { get }
}

extension SQLiteBacked {
    var database: OpaquePointer { connection.handle }

    func execute(_ sql: String) throws {
        try SQLiteSupport.execute(database: database, sql: sql)
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteStoreError.statement(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.step(String(cString: sqlite3_errmsg(database)))
        }
    }


    func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, SQLiteSupport.transient)
    }

    func bindOptional(_ value: String?, to statement: OpaquePointer, index: Int32) {
        if let value { bind(value, to: statement, index: index) }
        else { sqlite3_bind_null(statement, index) }
    }

    func bindOptional(_ value: Int?, to statement: OpaquePointer, index: Int32) {
        if let value { sqlite3_bind_int(statement, index, Int32(value)) }
        else { sqlite3_bind_null(statement, index) }
    }

    func bindOptional(_ value: Int64?, to statement: OpaquePointer, index: Int32) {
        if let value { sqlite3_bind_int64(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    func bindOptional(_ value: Double?, to statement: OpaquePointer, index: Int32) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func date(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }
}
