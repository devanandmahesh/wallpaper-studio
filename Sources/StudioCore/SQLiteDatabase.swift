import Foundation
import SQLite3

enum SQLValue {
    case int(Int64), double(Double), text(String), null

    init(_ v: Int?) { self = v.map { .int(Int64($0)) } ?? .null }
    init(_ v: Double?) { self = v.map { .double($0) } ?? .null }
    init(_ v: String?) { self = v.map { .text($0) } ?? .null }
}

struct SQLRow {
    let stmt: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : Int(int(i)) }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
}

/// Minimal wrapper over the system SQLite. Not thread-safe by itself: always used from inside the store actor.
final class SQLiteDatabase {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw LibraryError.database(message)
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    deinit { sqlite3_close(db) }

    private var errorMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown" }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try query(sql, params) { _ in () }
    }

    @discardableResult
    func query<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LibraryError.database(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw LibraryError.database(errorMessage) }
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(SQLRow(stmt: stmt))) }
            else if rc == SQLITE_DONE { break }
            else { throw LibraryError.database(errorMessage) }
        }
        return out
    }

    var changes: Int { Int(sqlite3_changes(db)) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
