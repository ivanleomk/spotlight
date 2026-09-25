import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

// SQLite copies text we hand it only if we pass this special "transient" marker.
// It's a C macro, which Swift can't import, so we recreate it.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// A value we can plug into a `?` placeholder in an SQL statement.
enum SQLiteValue {
    case text(String)
    case int(Int64)
    case double(Double)
}

// One row of a query result. Columns are numbered from 0, in SELECT order.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func string(_ column: Int32) -> String {
        // sqlite3_column_text returns NULL for a NULL value, hence the optional.
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
}

// Owns one open database. It's a class (not a struct) so that `deinit` can
// close the database exactly once, when the last reference goes away.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String) throws {
        // The C function fills in `handle` through the `&` pointer.
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw SQLiteError(description: message)
        }
    }

    deinit { sqlite3_close(handle) }

    // Runs one or more SQL statements that return no rows (CREATE TABLE, BEGIN, ...).
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError(description: message)
        }
    }

    // Runs a statement with `?` placeholders, calling `row` once per result row.
    // Values are bound separately from the SQL text, which prevents SQL injection.
    func query(_ sql: String, _ params: [SQLiteValue] = [], row: (SQLiteRow) -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
        }
        // `defer` runs when this function exits, however it exits, so we never leak the statement.
        defer { sqlite3_finalize(statement) }

        // Placeholder numbers start at 1, unlike column numbers, which start at 0.
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, SQLITE_TRANSIENT)
            case .int(let i): sqlite3_bind_int64(statement, index, i)
            case .double(let d): sqlite3_bind_double(statement, index, d)
            }
        }

        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW, let statement {
                row(SQLiteRow(statement: statement))
            } else if code == SQLITE_DONE {
                return
            } else {
                throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
