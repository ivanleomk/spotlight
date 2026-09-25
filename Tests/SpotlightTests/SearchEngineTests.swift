import Foundation
import Testing

@testable import Spotlight

@Suite struct SearchTests {
    @Test func findsFileByPrefixOfName() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/docs/invoice-2024.pdf", name: "invoice-2024.pdf")

        #expect(try await engine.titles(for: "inv") == ["invoice-2024.pdf"])
    }

    @Test func resultsCarryPathAndKind() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/Applications/Safari.app", name: "Safari", kind: .app)

        let result = try #require(try await engine.search(SearchQuery(text: "safari")).first)

        #expect(result.subtitle == "/Applications/Safari.app")
        #expect(result.kind == .app)
    }

    @Test func nameMatchOutranksContentMatch() async throws {
        let engine = try makeEngine()
        // BM25's rarity weighting needs a reasonably sized corpus, so add filler files.
        for i in 0..<10 {
            try await engine.upsert(path: "/filler/file\(i).txt", name: "file\(i).txt")
        }
        try await engine.upsert(path: "/a/notes.md", name: "notes.md", content: "invoice draft")
        try await engine.upsert(path: "/b/invoice.pdf", name: "invoice.pdf")

        let results = try await engine.search(SearchQuery(text: "invoice"))

        #expect(results.map(\.title) == ["invoice.pdf", "notes.md"])
    }

    @Test func everyWordMustMatch() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/tax-2024.pdf", name: "tax-2024.pdf")
        try await engine.upsert(path: "/a/tax-2023.pdf", name: "tax-2023.pdf")

        #expect(try await engine.titles(for: "tax 2024") == ["tax-2024.pdf"])
    }

    @Test func camelCaseNamesMatchTheirParts() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/src/SearchPanel.swift", name: "SearchPanel.swift")

        #expect(try await engine.titles(for: "panel") == ["SearchPanel.swift"])
    }

    @Test func respectsLimit() async throws {
        let engine = try makeEngine()
        for i in 0..<5 {
            try await engine.upsert(path: "/x/note\(i).txt", name: "note\(i).txt")
        }

        let results = try await engine.search(SearchQuery(text: "note", limit: 2))

        #expect(results.count == 2)
    }

    @Test func filtersByKind() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/Applications/Safari.app", name: "Safari", kind: .app)
        try await engine.upsert(path: "/docs/safari-notes.md", name: "safari-notes.md")
        try await engine.upsert(path: "/docs/Safari Stuff", name: "Safari Stuff", kind: .folder)

        #expect(try await engine.titles(for: "saf", kinds: [.app]) == ["Safari"])
        #expect(
            try await engine.titles(for: "saf", kinds: [.file, .folder])
                == ["safari-notes.md", "Safari Stuff"])
        #expect(try await engine.titles(for: "saf").count == 3)
    }

    @Test func emptyOrSymbolOnlyQueriesReturnNothing() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/notes.md", name: "notes.md")

        #expect(try await engine.titles(for: "").isEmpty)
        #expect(try await engine.titles(for: #"  -:"* "#).isEmpty)
    }

    @Test func specialCharactersInQueryDoNotThrow() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/notes.md", name: "notes.md")

        // Raw FTS5 would treat these as syntax and throw; our sanitizer must not.
        #expect(try await engine.titles(for: #"notes" OR (foo:"#).isEmpty)
    }
}

@Suite struct SnippetTests {
    @Test func snippetShowsOnlyWhenTheMatchIsInTheContent() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/notes.md", name: "notes.md", content: "buy oat milk")
        try await engine.upsert(path: "/a/oat.md", name: "oat.md", content: "oat oat oat")

        let results = try await engine.search(SearchQuery(text: "oat"))
        let byTitle = Dictionary(uniqueKeysWithValues: results.map { ($0.title, $0) })

        #expect(byTitle["notes.md"]?.snippet == "buy \u{2}oat\u{3} milk")
        // The name already shows why it matched, so no snippet.
        #expect(byTitle["oat.md"]?.snippet == nil)
    }

    @Test func pathOnlyMatchesHaveNoSnippet() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/projects/zeppelin/readme.md", name: "readme.md", content: "hello")

        let result = try #require(try await engine.search(SearchQuery(text: "zeppelin")).first)

        #expect(result.snippet == nil)
    }
}

@Suite struct IndexMaintenanceTests {
    @Test func upsertingTheSamePathUpdatesInsteadOfDuplicating() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/report.txt", name: "report.txt", content: "draft")
        try await engine.upsert(path: "/a/report.txt", name: "report.txt", content: "final")

        #expect(try await engine.search(SearchQuery(text: "report")).count == 1)
        #expect(try await engine.titles(for: "draft").isEmpty)
        #expect(try await engine.titles(for: "final") == ["report.txt"])
    }

    @Test func pruneRemovesOnlyStaleItemsUnderItsOwnRoot() async throws {
        let engine = try makeEngine()
        // "/a/b" must not be treated as containing "/a/bc/...".
        try await engine.upsert(
            [
                IndexedFile(path: "/a/b/old.txt", name: "old.txt"),
                IndexedFile(path: "/a/bc/keep.txt", name: "keep.txt"),
            ], indexedAt: 1)
        try await engine.upsert([IndexedFile(path: "/a/b/fresh.txt", name: "fresh.txt")], indexedAt: 3)

        try await engine.prune(under: "/a/b", olderThan: 2)

        #expect(try await engine.titles(for: "old").isEmpty)
        #expect(try await engine.titles(for: "fresh") == ["fresh.txt"])
        #expect(try await engine.titles(for: "keep") == ["keep.txt"])
    }

    @Test func pruneTreatsUnderscoresAndPercentsLiterally() async throws {
        let engine = try makeEngine()
        // With LIKE, "_" would match any character, so "/a_b" would also match "/axb".
        try await engine.upsert(
            [
                IndexedFile(path: "/a_b/one.txt", name: "one.txt"),
                IndexedFile(path: "/axb/two.txt", name: "two.txt"),
            ], indexedAt: 1)

        try await engine.prune(under: "/a_b", olderThan: 2)

        #expect(try await engine.titles(for: "one").isEmpty)
        #expect(try await engine.titles(for: "two") == ["two.txt"])
    }

    @Test func touchKeepsItemsThroughPrune() async throws {
        let engine = try makeEngine()
        try await engine.upsert([IndexedFile(path: "/r/kept.txt", name: "kept.txt")], indexedAt: 1)

        try await engine.touch(["/r/kept.txt"], indexedAt: 5)
        try await engine.prune(under: "/r", olderThan: 5)

        #expect(try await engine.titles(for: "kept") == ["kept.txt"])
    }

    @Test func modificationDatesAreScopedToTheRoot() async throws {
        let engine = try makeEngine()
        try await engine.upsert([
            IndexedFile(path: "/r/a.txt", name: "a.txt", modifiedAt: 10),
            IndexedFile(path: "/other/b.txt", name: "b.txt", modifiedAt: 20),
        ])

        #expect(try await engine.modificationDates(under: "/r") == ["/r/a.txt": 10])
    }
}

@Suite struct IndexStatsTests {
    @Test func emptyIndexHasNoItemsAndNoDate() async throws {
        let stats = try await makeEngine().stats()

        #expect(stats.itemCount == 0)
        #expect(stats.lastIndexed == nil)
    }

    @Test func countsItemsPerFolderAndOverall() async throws {
        let engine = try makeEngine()
        try await engine.upsert(
            [
                IndexedFile(path: "/a/one.txt", name: "one.txt"),
                IndexedFile(path: "/a/two.txt", name: "two.txt"),
                IndexedFile(path: "/ab/three.txt", name: "three.txt"),
            ], indexedAt: 100)

        #expect(try await engine.count(under: "/a") == 2)
        #expect(try await engine.count(under: "/ab") == 1)
        let stats = try await engine.stats()
        #expect(stats.itemCount == 3)
        #expect(stats.lastIndexed == Date(timeIntervalSince1970: 100))
    }
}

@Suite struct SchemaTests {
    private func userVersion(at path: String) throws -> Int64 {
        var version: Int64 = -1
        try SQLiteConnection(path: path).query("PRAGMA user_version") { version = $0.int(0) }
        return version
    }

    @Test func newDatabaseIsAtTheCurrentVersion() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let path = folder.url.appendingPathComponent("index.sqlite").path

        _ = try SQLiteSearchEngine(path: path)

        #expect(try userVersion(at: path) == Int64(SQLiteSearchEngine.schemaVersion))
    }

    @Test func olderDatabaseIsRebuilt() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let path = folder.url.appendingPathComponent("index.sqlite").path
        // An old-style database whose `documents` table has the wrong columns.
        let old = try SQLiteConnection(path: path)
        try old.execute("CREATE TABLE documents (junk TEXT); PRAGMA user_version = 1")

        let engine = try SQLiteSearchEngine(path: path)
        try await engine.upsert(path: "/a/notes.md", name: "notes.md")

        #expect(try await engine.titles(for: "notes") == ["notes.md"])
        #expect(try userVersion(at: path) == Int64(SQLiteSearchEngine.schemaVersion))
    }

    // v4 -> v5 is the first upgrade that keeps data: it adds a column instead of
    // rebuilding, so nothing has to be crawled (or downloaded) again.
    @Test func version4DatabaseIsUpgradedInPlace() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let path = folder.url.appendingPathComponent("index.sqlite").path
        // A database exactly as v4 left it, holding one indexed file.
        let old = try SQLiteConnection(path: path)
        try old.execute(
            """
            CREATE TABLE documents (
              id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
              kind TEXT NOT NULL DEFAULT 'file', size INTEGER, modified_at REAL,
              indexed_at REAL NOT NULL DEFAULT 0);
            CREATE VIRTUAL TABLE documents_fts USING fts5(
              name, path, content, tokenize = 'unicode61 remove_diacritics 2');
            INSERT INTO documents(id, path, name) VALUES (1, '/a/kept.md', 'kept.md');
            INSERT INTO documents_fts(rowid, name, path, content) VALUES (1, 'kept.md', '/a/kept.md', '');
            PRAGMA user_version = 4;
            """)

        let engine = try SQLiteSearchEngine(path: path)

        #expect(try await engine.titles(for: "kept") == ["kept.md"])
        #expect(try userVersion(at: path) == Int64(SQLiteSearchEngine.schemaVersion))
        // Old rows were all crawled files, so they belong to the files source.
        try await engine.removeAll(from: LocalFilesSource.sourceID)
        #expect(try await engine.titles(for: "kept").isEmpty)
    }

    @Test func reopeningKeepsTheIndex() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let path = folder.url.appendingPathComponent("index.sqlite").path
        try await SQLiteSearchEngine(path: path).upsert(path: "/a/notes.md", name: "notes.md")

        let reopened = try SQLiteSearchEngine(path: path)

        #expect(try await reopened.titles(for: "notes") == ["notes.md"])
    }
}
