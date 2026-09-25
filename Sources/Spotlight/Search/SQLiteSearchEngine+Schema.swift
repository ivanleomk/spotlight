import Foundation

// The database layout, and upgrading older databases to it. An `extension`
// adds more members to an existing type, here from a separate file.
extension SQLiteSearchEngine {
    // Bump this when the schema changes. SQLite keeps the number in the file itself
    // (PRAGMA user_version), so we can tell which version an existing database is.
    static let schemaVersion = 5

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
          source      TEXT NOT NULL DEFAULT 'files'
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
