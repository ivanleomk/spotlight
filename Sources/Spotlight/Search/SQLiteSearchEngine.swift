import Foundation

// One thing to put in the index.
struct IndexedFile: Sendable {
    var path: String
    var name: String
    var kind: DocumentKind = .file
    var size: Int64 = 0
    var modifiedAt: Double = 0
    var content: String = ""
    // A short second line shown in results (see SearchResult.detail).
    var detail: String = ""
    // The Source it came from (see Source.id).
    var source: String = LocalFilesSource.sourceID
}

// What a source remembers between syncs.
struct SyncState: Sendable, Equatable {
    // The source's bookmark: Gmail's historyId, Drive's page token. Nil for
    // sources that always look at everything (local files).
    var cursor: String?
    var syncedAt: Date
}

struct IndexStats: Sendable {
    var itemCount = 0
    var lastIndexed: Date?
}

// An `actor` is a class that protects its own data: only one caller at a time can
// run inside it, so the (not thread-safe) database connection is never touched
// from two threads at once. Callers reach it with `await`.
actor SQLiteSearchEngine: SearchEngine {
    // Not private: the extensions in other files (schema, training log) use it too.
    let db: SQLiteConnection
    // The current time, replaceable so tests can pin "now" for recency ranking.
    var now: @Sendable () -> Date = Date.init

    func setClock(_ clock: @escaping @Sendable () -> Date) { now = clock }

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
                    INSERT INTO documents(path, name, kind, size, modified_at, indexed_at, source, detail)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        name = excluded.name, kind = excluded.kind, size = excluded.size,
                        modified_at = excluded.modified_at, indexed_at = excluded.indexed_at,
                        source = excluded.source, detail = excluded.detail
                    RETURNING id
                    """,
                    [
                        .text(file.path), .text(file.name), .text(file.kind.rawValue),
                        .int(file.size), .double(file.modifiedAt), .double(indexedAt),
                        .text(file.source), .text(file.detail),
                    ]
                ) { id = $0.int(0) }

                // The search index is a separate table, so we keep it in sync by hand:
                // delete the old entry (if any), then insert the fresh one.
                try db.query("DELETE FROM documents_fts WHERE rowid = ?", [.int(id)])
                try db.query(
                    "INSERT INTO documents_fts(rowid, name, path, content) VALUES(?, ?, ?, ?)",
                    [
                        .int(id), .text(SearchText.indexable(file.name)),
                        // Web links (email, Drive) aren't searchable: their "words"
                        // (mail, google, your own address) would match everything.
                        .text(file.path.hasPrefix("https://") ? "" : SearchText.indexable(file.path)),
                        .text(file.content),
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
        let (under, underParams) = Self.pathIsUnder(root)
        let stale = "\(under) AND indexed_at < ?"
        let params = underParams + [.double(cutoff)]
        try inTransaction {
            try db.query("DELETE FROM documents_fts WHERE rowid IN (SELECT id FROM documents WHERE \(stale))", params)
            try db.query("DELETE FROM documents WHERE \(stale)", params)
        }
    }

    // Removes specific items, e.g. emails deleted in Gmail.
    func remove(paths: [String]) throws {
        try inTransaction {
            for path in paths {
                try db.query(
                    "DELETE FROM documents_fts WHERE rowid IN (SELECT id FROM documents WHERE path = ?)",
                    [.text(path)])
                try db.query("DELETE FROM documents WHERE path = ?", [.text(path)])
            }
        }
    }

    // Removes a source's items that weren't stamped at or after `cutoff`: for
    // sources that re-read everything each sync (Calendar), what's left
    // unstamped was deleted or has moved out of the window we index.
    func prune(source: String, olderThan cutoff: Double) throws {
        let stale = "source = ? AND indexed_at < ?"
        let params: [SQLiteValue] = [.text(source), .double(cutoff)]
        try inTransaction {
            try db.query("DELETE FROM documents_fts WHERE rowid IN (SELECT id FROM documents WHERE \(stale))", params)
            try db.query("DELETE FROM documents WHERE \(stale)", params)
        }
    }

    // Every path a source has indexed, so a sync that was interrupted can skip
    // what it already fetched instead of downloading it again.
    func paths(from source: String) throws -> Set<String> {
        var paths = Set<String>()
        try db.query("SELECT path FROM documents WHERE source = ?", [.text(source)]) { paths.insert($0.string(0)) }
        return paths
    }

    func count(from source: String) throws -> Int {
        var count = 0
        try db.query("SELECT count(*) FROM documents WHERE source = ?", [.text(source)]) { count = Int($0.int(0)) }
        return count
    }

    // Forgets everything one source added, e.g. when you disconnect an account.
    func removeAll(from source: String) throws {
        try inTransaction {
            try db.query(
                "DELETE FROM documents_fts WHERE rowid IN (SELECT id FROM documents WHERE source = ?)",
                [.text(source)])
            try db.query("DELETE FROM documents WHERE source = ?", [.text(source)])
            try db.query("DELETE FROM sync_state WHERE source = ?", [.text(source)])
        }
    }

    // MARK: - Sync state

    // Where `source` got up to last time, or nil if it has never synced.
    func syncState(for source: String) throws -> SyncState? {
        var state: SyncState?
        try db.query("SELECT cursor, synced_at FROM sync_state WHERE source = ?", [.text(source)]) { row in
            // A NULL cursor comes back as "", which means "no cursor".
            let cursor = row.string(0)
            state = SyncState(
                cursor: cursor.isEmpty ? nil : cursor,
                syncedAt: Date(timeIntervalSince1970: row.double(1)))
        }
        return state
    }

    func saveSyncState(_ state: SyncState, for source: String) throws {
        try db.query(
            """
            INSERT INTO sync_state(source, cursor, synced_at) VALUES(?, ?, ?)
            ON CONFLICT(source) DO UPDATE SET cursor = excluded.cursor, synced_at = excluded.synced_at
            """,
            [.text(source), .text(state.cursor ?? ""), .double(state.syncedAt.timeIntervalSince1970)])
    }

    // MARK: - Stats

    // Numbers for the Settings page.
    func stats() throws -> IndexStats {
        var stats = IndexStats()
        try db.query("SELECT count(*), max(indexed_at) FROM documents") { row in
            stats.itemCount = Int(row.int(0))
            let last = row.double(1)
            stats.lastIndexed = last > 0 ? Date(timeIntervalSince1970: last) : nil
        }
        return stats
    }

    // How many items are indexed inside folder `root`.
    func count(under root: String) throws -> Int {
        let (under, params) = Self.pathIsUnder(root)
        var count = 0
        try db.query("SELECT count(*) FROM documents WHERE \(under)", params) { count = Int($0.int(0)) }
        return count
    }

    // Path -> modification date for everything already indexed under `root`.
    // The crawler compares against this to skip re-reading files that haven't changed.
    func modificationDates(under root: String) throws -> [String: Double] {
        let (under, params) = Self.pathIsUnder(root)
        var dates: [String: Double] = [:]
        try db.query("SELECT path, modified_at FROM documents WHERE \(under)", params) { row in
            dates[row.string(0)] = row.double(1)
        }
        return dates
    }

    // Marks files as "still there" without rewriting them, so `prune` keeps them.
    func touch(_ paths: [String], indexedAt: Double) throws {
        try inTransaction {
            for path in paths {
                try db.query(
                    "UPDATE documents SET indexed_at = ? WHERE path = ?", [.double(indexedAt), .text(path)])
            }
        }
    }

    // SQL meaning "path is inside folder `root`", plus the values for its placeholders.
    // substr(...) = prefix means "path starts with prefix". We avoid LIKE because
    // `_` and `%` in real file names would be treated as wildcards.
    private static func pathIsUnder(_ root: String) -> (String, [SQLiteValue]) {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        // SQLite counts Unicode code points, while Swift's `count` counts what you see
        // as one letter ("é" can be two code points), so we count code points too.
        let length = Int64(prefix.unicodeScalars.count)
        return ("substr(path, 1, ?) = ?", [.int(length), .text(prefix)])
    }

    // Runs `body` as one all-or-nothing unit: if anything throws, nothing is kept.
    // Also far faster than one commit per file when writing thousands of rows.
    func inTransaction(_ body: () throws -> Void) throws {
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
        guard let match = SearchText.matchExpression(from: query.text) else { return [] }

        // One `?` per kind, e.g. "AND d.kind IN (?, ?)". Only the placeholders go
        // into the SQL text; the values themselves are still bound safely.
        var kindFilter = ""
        var params: [SQLiteValue] = [.text(match)]
        if !query.kinds.isEmpty {
            kindFilter = "AND d.kind IN (" + query.kinds.map { _ in "?" }.joined(separator: ", ") + ")"
            params += query.kinds.map { .text($0.rawValue) }
        }
        // BM25 picks the best text matches, then Ranking reorders them by how
        // recent they are. Fetching several times the limit gives the reordering
        // room to promote a slightly weaker but much more recent match.
        params.append(.int(Int64(query.limit * Ranking.candidateMultiplier)))

        var results: [SearchResult] = []
        try db.query(
            """
            -- char(2) and char(3) are MatchMarker.start and .end.
            SELECT d.id, d.name, d.path, d.kind, -bm25(documents_fts, 10.0, 2.0, 1.0),
                   highlight(documents_fts, 0, char(2), char(3)),
                   snippet(documents_fts, 2, char(2), char(3), '…', 12),
                   d.detail, d.modified_at
            FROM documents_fts JOIN documents d ON d.id = documents_fts.rowid
            WHERE documents_fts MATCH ? \(kindFilter)
            ORDER BY bm25(documents_fts, 10.0, 2.0, 1.0)
            LIMIT ?
            """,
            params
        ) { row in
            // highlight() returns the name with matches wrapped in MatchMarkers;
            // snippet() does the same for a short excerpt of the content. A snippet
            // is only worth showing when the match is in the content and not
            // already visible in the name.
            let nameMatched = row.string(5).contains(MatchMarker.start)
            let snippet = row.string(6)
            let detail = row.string(7)
            let modified = row.double(8)
            results.append(
                SearchResult(
                    id: String(row.int(0)), title: row.string(1), subtitle: row.string(2),
                    kind: DocumentKind(rawValue: row.string(3)) ?? .file, score: row.double(4),
                    detail: detail.isEmpty ? nil : detail,
                    date: modified > 0 ? Date(timeIntervalSince1970: modified) : nil,
                    snippet: !nameMatched && snippet.contains(MatchMarker.start) ? snippet : nil))
        }
        return Array(Ranking.rerank(results, now: now()).prefix(query.limit))
    }
}
