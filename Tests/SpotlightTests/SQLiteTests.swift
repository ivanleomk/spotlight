import Testing

@testable import Spotlight

// The thin wrapper around SQLite's C API.
@Suite struct SQLiteConnectionTests {
    private func makeTable() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE t (name TEXT, count INTEGER, ratio REAL)")
        return db
    }

    @Test func roundTripsTextIntegersAndDoubles() throws {
        let db = try makeTable()
        try db.query("INSERT INTO t VALUES (?, ?, ?)", [.text("héllo"), .int(42), .double(0.5)])

        var row: (String, Int64, Double)?
        try db.query("SELECT name, count, ratio FROM t") { row = ($0.string(0), $0.int(1), $0.double(2)) }

        #expect(row?.0 == "héllo")
        #expect(row?.1 == 42)
        #expect(row?.2 == 0.5)
    }

    @Test func placeholderValuesAreNeverRunAsSQL() throws {
        let db = try makeTable()
        let nasty = "x'); DROP TABLE t; --"
        try db.query("INSERT INTO t (name) VALUES (?)", [.text(nasty)])

        var names: [String] = []
        try db.query("SELECT name FROM t") { names.append($0.string(0)) }

        #expect(names == [nasty])  // stored as plain text, and the table still exists
    }

    @Test func badSQLThrows() throws {
        let db = try makeTable()

        #expect(throws: SQLiteError.self) { try db.execute("SELEC nonsense") }
        #expect(throws: SQLiteError.self) { try db.query("SELECT missing FROM t") }
    }

    @Test func queryWithNoRowsNeverCallsTheRowClosure() throws {
        let db = try makeTable()
        var calls = 0

        try db.query("SELECT * FROM t") { _ in calls += 1 }

        #expect(calls == 0)
    }

    @Test func nullTextReadsAsEmptyString() throws {
        let db = try makeTable()
        try db.query("INSERT INTO t (count) VALUES (1)")

        var name: String?
        try db.query("SELECT name FROM t") { name = $0.string(0) }

        #expect(name == "")
    }
}
