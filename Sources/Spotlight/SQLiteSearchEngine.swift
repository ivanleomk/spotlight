import Foundation

// One thing to put in the index.
struct IndexedFile: Sendable {
    var path: String
    var name: String
    var kind: DocumentKind = .file
    var size: Int64 = 0
    var modifiedAt: Double = 0
    var content: String = ""
}

// An `actor` is a class that protects its own data: only one caller at a time can
// run inside it, so the (not thread-safe) database connection is never touched
// from two threads at once. Callers reach it with `await`.
actor SQLiteSearchEngine: SearchEngine {
    private let db: SQLiteConnection

    // Pass ":memory:" for a throwaway in-RAM database (used by tests).
    init(path: String) throws {
        db = try SQLiteConnection(path: path)
        try db.execute("PRAGMA foreign_keys = ON")  // off by default in SQLite!
        try db.execute("PRAGMA journal_mode = WAL")  // faster writes, readers don't block
        try Self.migrate(db)
    }

    // Where the real index lives: ~/Library/Application Support/Spotlight/index.sqlite
    static func defaultDatabasePath() throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("Spotlight", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("index.sqlite").path
    }

    // MARK: - Indexing

    // Adds files to the index, or updates them if the path is already there.
    // `indexedAt` stamps each row so a later `prune` can tell which rows weren't seen.
    func upsert(_ files: [IndexedFile], indexedAt: Double = Date().timeIntervalSince1970) throws {
        try inTransaction {
            for file in files {
                // RETURNING hands back the row's id in the same statement, whether it
                // was just inserted or already existed.
                var id: Int64 = 0
                try db.query(
                    """
                    INSERT INTO documents(path, name, kind, size, modified_at, indexed_at)
                    VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        name = excluded.name, kind = excluded.kind, size = excluded.size,
                        modified_at = excluded.modified_at, indexed_at = excluded.indexed_at
                    RETURNING id
                    """,
                    [
                        .text(file.path), .text(file.name), .text(file.kind.rawValue),
                        .int(file.size), .double(file.modifiedAt), .double(indexedAt),
                    ]
                ) { id = $0.int(0) }

                // The search index is a separate table, so we keep it in sync by hand:
                // delete the old entry (if any), then insert the fresh one.
                try db.query("DELETE FROM documents_fts WHERE rowid = ?", [.int(id)])
                try db.query(
                    "INSERT INTO documents_fts(rowid, name, path, content) VALUES(?, ?, ?, ?)",
                    [
                        .int(id), .text(Self.searchable(file.name)),
                        .text(Self.searchable(file.path)), .text(file.content),
                    ])
            }
        }
    }

    // Convenience for adding a single file (handy in tests).
    func upsert(
        path: String, name: String, kind: DocumentKind = .file, content: String = ""
    ) throws {
        try upsert([IndexedFile(path: path, name: name, kind: kind, content: content)])
    }

    // Removes everything under `root` that wasn't stamped at or after `cutoff`,
    // i.e. files that existed at the last crawl but are gone now.
    func prune(under root: String, olderThan cutoff: Double) throws {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        // substr(...) = prefix means "path starts with prefix". We avoid LIKE because
        // `_` and `%` in real file names would be treated as wildcards.
        let stale = "substr(path, 1, ?) = ? AND indexed_at < ?"
        // SQLite counts Unicode code points, while Swift's `count` counts what you see
        // as one letter ("é" can be two code points), so we count code points too.
        let length = Int64(prefix.unicodeScalars.count)
        let params: [SQLiteValue] = [.int(length), .text(prefix), .double(cutoff)]
        try inTransaction {
            try db.query("DELETE FROM documents_fts WHERE rowid IN (SELECT id FROM documents WHERE \(stale))", params)
            try db.query("DELETE FROM documents WHERE \(stale)", params)
        }
    }

    // Runs `body` as one all-or-nothing unit: if anything throws, nothing is kept.
    // Also far faster than one commit per file when writing thousands of rows.
    private func inTransaction(_ body: () throws -> Void) throws {
        try db.execute("BEGIN")
        do {
            try body()
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Searching

    func search(_ query: SearchQuery) async throws -> [SearchResult] {
        guard let match = Self.matchExpression(from: query.text) else { return [] }

        var results: [SearchResult] = []
        try db.query(
            """
            SELECT d.id, d.name, d.path, d.kind, -bm25(documents_fts, 10.0, 2.0, 1.0)
            FROM documents_fts JOIN documents d ON d.id = documents_fts.rowid
            WHERE documents_fts MATCH ?
            ORDER BY bm25(documents_fts, 10.0, 2.0, 1.0)
            LIMIT ?
            """,
            [.text(match), .int(Int64(query.limit))]
        ) { row in
            results.append(
                SearchResult(
                    id: String(row.int(0)), title: row.string(1), subtitle: row.string(2),
                    kind: DocumentKind(rawValue: row.string(3)) ?? .file, score: row.double(4)))
        }
        return results
    }

    // Turns what the user typed into a safe FTS5 query: "note app" -> "note"* "app"*
    // Raw input could contain characters FTS5 treats as syntax (quotes, -, :), so we
    // keep only letters and digits, quote each word, and add * so the last word can
    // still be half-typed.
    static func matchExpression(from text: String) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // The index splits words at punctuation ("my-notes.md" -> my, notes, md) but not
    // at camelCase, so "SearchPanel" would be one word and a search for "panel" would
    // miss it. We add a split copy: "SearchPanel" -> "SearchPanel Search Panel".
    static func searchable(_ text: String) -> String {
        var split = ""
        var previous: Character?
        for character in text {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                split.append(" ")
            }
            split.append(character)
            previous = character
        }
        return split == text ? text : text + " " + split
    }

    // MARK: - Schema

    // Bump this when the schema changes. SQLite keeps the number in the file itself
    // (PRAGMA user_version), so we can tell which version an existing database is.
    private static let schemaVersion = 2

    private static func migrate(_ db: SQLiteConnection) throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }

        if version < schemaVersion {
            // Old databases only held a throwaway index, so we rebuild from scratch.
            // Once `searches` holds real history, future migrations must ALTER the
            // tables instead of dropping them.
            try db.execute(
                """
                DROP TABLE IF EXISTS search_results;
                DROP TABLE IF EXISTS searches;
                DROP TABLE IF EXISTS documents_fts;
                DROP TABLE IF EXISTS documents;
                """)
        }
        try db.execute(schema)
        try db.execute("PRAGMA user_version = \(schemaVersion)")
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS documents (
          id          INTEGER PRIMARY KEY,
          path        TEXT NOT NULL UNIQUE,
          name        TEXT NOT NULL,
          kind        TEXT NOT NULL DEFAULT 'file',
          size        INTEGER,
          modified_at REAL,
          indexed_at  REAL NOT NULL DEFAULT 0
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
          name, path, content,
          tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TABLE IF NOT EXISTS searches (
          id      INTEGER PRIMARY KEY,
          query   TEXT NOT NULL,
          ranker  TEXT NOT NULL,
          at      REAL NOT NULL,
          outcome TEXT NOT NULL CHECK (outcome IN ('selected', 'dismissed'))
        );

        CREATE TABLE IF NOT EXISTS search_results (
          search_id   INTEGER NOT NULL REFERENCES searches(id)  ON DELETE CASCADE,
          document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          position    INTEGER NOT NULL,
          score       REAL,
          chosen      INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (search_id, position)
        );
        """
}
