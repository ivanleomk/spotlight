import Foundation

// A second, read-only connection to the index, just for the search panel.
//
// The engine (an actor) does one thing at a time, so when searches shared it
// with syncing, every keystroke waited behind whatever batch of emails was
// being written. SQLite's WAL mode lets a reader and a writer work at the same
// time on separate connections; this actor is that separate reader.
actor SearchReader: SearchEngine {
    private let db: SQLiteConnection
    private let now: @Sendable () -> Date

    // Open the engine first: it creates and upgrades the database.
    init(path: String, now: @escaping @Sendable () -> Date = Date.init) throws {
        db = try SQLiteConnection(path: path)
        try db.execute("PRAGMA query_only = ON")   // refuse writes, just in case
        try db.execute("PRAGMA busy_timeout = 1000")  // wait briefly instead of failing if locked
        self.now = now
    }

    func search(_ query: SearchQuery) async throws -> [SearchResult] {
        try SQLiteSearchEngine.runSearch([query], on: db, now: now()).first ?? []
    }

    func search(_ queries: [SearchQuery]) async throws -> [[SearchResult]] {
        try SQLiteSearchEngine.runSearch(queries, on: db, now: now())
    }
}
