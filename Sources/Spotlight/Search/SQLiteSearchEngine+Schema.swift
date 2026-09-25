import Foundation

// The database layout, and upgrading older databases to it. An `extension`
// adds more members to an existing type, here from a separate file.
extension SQLiteSearchEngine {
    // Bump this when the schema changes. SQLite keeps the number in the file itself
    // (PRAGMA user_version), so we can tell which version an existing database is.
    static let schemaVersion = 7

    static func migrate(_ db: SQLiteConnection) throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }

        if version < 4 {
            // Too old to upgrade (and brand-new files, at 0): start from scratch.
            // Before v4 the index was a throwaway, so nothing is lost.
            // (v3: file contents are indexed. v4: but not inside /Applications.)
            try db.execute(
                """
                DROP TABLE IF EXISTS search_results;
                DROP TABLE IF EXISTS searches;
                DROP TABLE IF EXISTS impressions;
                DROP TABLE IF EXISTS selections;
                DROP TABLE IF EXISTS documents_fts;
                DROP TABLE IF EXISTS documents;
                """)
            // Dropping tables frees the space inside the file but doesn't shrink the
            // file; VACUUM rewrites it at its real size.
            try db.execute("VACUUM")
        } else {
            // From v4 on, upgrade in place, one step per version, so the index
            // (and later, synced email) survives. Each step runs only once: after
            // it, user_version is past it.
            if version < 5 {
                // v5: every row remembers which source it came from. Existing rows
                // all came from the file crawler, hence the default.
                try db.execute("ALTER TABLE documents ADD COLUMN source TEXT NOT NULL DEFAULT 'files'")
            }
            if version < 6 {
                // v6: a second line for results from other sources (sender, location).
                try db.execute("ALTER TABLE documents ADD COLUMN detail TEXT NOT NULL DEFAULT ''")
            }
            if version < 7 {
                // v7: the never-used search log tables are replaced by `selections`
                // and `impressions` (created below). They were always empty.
                try db.execute("DROP TABLE IF EXISTS search_results; DROP TABLE IF EXISTS searches;")
            }
        }
        // Creates whatever doesn't exist yet (all of it for a new database, just
        // the new v5 table and index for an upgraded one).
        try db.execute(schema)
        try db.execute("PRAGMA user_version = \(schemaVersion)")
    }

    static let schema = """
        CREATE TABLE IF NOT EXISTS documents (
          id          INTEGER PRIMARY KEY,
          path        TEXT NOT NULL UNIQUE,
          name        TEXT NOT NULL,
          kind        TEXT NOT NULL DEFAULT 'file',
          size        INTEGER,
          modified_at REAL,
          indexed_at  REAL NOT NULL DEFAULT 0,
          -- Which Source the row came from: 'files', 'gmail', 'drive'. For files,
          -- `path` is a file path; for the others, a web link to open.
          source      TEXT NOT NULL DEFAULT 'files',
          -- A short second line for results: an email's sender, an event's location.
          detail      TEXT NOT NULL DEFAULT ''
        );

        CREATE INDEX IF NOT EXISTS documents_by_source ON documents(source);

        -- Where each source got up to, so the next sync only fetches what changed.
        CREATE TABLE IF NOT EXISTS sync_state (
          source    TEXT PRIMARY KEY,
          cursor    TEXT,
          synced_at REAL NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
          name, path, content,
          tokenize = 'unicode61 remove_diacritics 2'
        );

        -- Training data: each time you open a result, what you searched for and
        -- what was on screen. Turned into (query, opened, negatives) on export.
        CREATE TABLE IF NOT EXISTS selections (
          id              INTEGER PRIMARY KEY,
          query           TEXT NOT NULL,
          at              REAL NOT NULL,
          ranker          TEXT NOT NULL,   -- which ranking produced the order
          chosen_position INTEGER NOT NULL
        );

        -- Every result shown for a selection, top to bottom. A copy of its text,
        -- not a link to `documents`: emails and events leave the index over time,
        -- and the training pair has to outlive them.
        CREATE TABLE IF NOT EXISTS impressions (
          selection_id INTEGER NOT NULL REFERENCES selections(id) ON DELETE CASCADE,
          position     INTEGER NOT NULL,
          doc_id       TEXT NOT NULL,   -- the item's path or link; stable off this Mac
          source       TEXT NOT NULL,
          kind         TEXT NOT NULL,
          title        TEXT NOT NULL,
          text         TEXT NOT NULL,   -- title, second line, start of content
          score        REAL NOT NULL,
          PRIMARY KEY (selection_id, position)
        );
        """
}
