import Foundation
import Testing

@testable import Spotlight

// Each @Test function is one check. `#expect(...)` records a failure if false.
@Suite struct SQLiteSearchEngineTests {
    // ":memory:" = a fresh throwaway database, so tests never touch real data.
    private func makeEngine() throws -> SQLiteSearchEngine {
        try SQLiteSearchEngine(path: ":memory:")
    }

    @Test func findsFileByPrefixOfName() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/docs/invoice-2024.pdf", name: "invoice-2024.pdf")

        let results = try await engine.search(SearchQuery(text: "inv"))

        #expect(results.map(\.title) == ["invoice-2024.pdf"])
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

    @Test func upsertingTheSamePathDoesNotDuplicate() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/report.txt", name: "report.txt")
        try await engine.upsert(path: "/a/report.txt", name: "report.txt", content: "updated")

        let results = try await engine.search(SearchQuery(text: "report"))

        #expect(results.count == 1)
    }

    @Test func respectsLimit() async throws {
        let engine = try makeEngine()
        for i in 0..<5 {
            try await engine.upsert(path: "/x/note\(i).txt", name: "note\(i).txt")
        }

        let results = try await engine.search(SearchQuery(text: "note", limit: 2))

        #expect(results.count == 2)
    }

    @Test func emptyOrSymbolOnlyQueriesReturnNothing() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/notes.md", name: "notes.md")

        #expect(try await engine.search(SearchQuery(text: "")).isEmpty)
        #expect(try await engine.search(SearchQuery(text: "  -:\"* ")).isEmpty)
    }

    @Test func specialCharactersInQueryDoNotBreakSearch() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/notes.md", name: "notes.md")

        // Raw FTS5 would treat these as syntax and throw; our sanitizer must not.
        let results = try await engine.search(SearchQuery(text: "notes\" OR (foo:"))

        #expect(results.isEmpty)  // "notes" AND "or" AND "foo" doesn't match, but must not throw
    }
}

@Suite struct FileCrawlerTests {
    // Builds a small fake folder tree in a fresh temporary folder:
    //
    //   Notes.md                     file
    //   Projects/                    folder
    //   Projects/node_modules/lodash.js   skipped (junk folder)
    //   .secret.txt                  skipped (hidden)
    //   Calculator.app/Contents/Info.plist   app; its insides are skipped
    //
    // The temp folder lives under /var, which is a symlink to /private/var, so this
    // also checks that the crawler copes with a root reached through a symlink.
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrawlerTest-\(UUID().uuidString)")
        let files = [
            "Notes.md", "Projects/node_modules/lodash.js", ".secret.txt",
            "Calculator.app/Contents/Info.plist",
        ]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: url)
        }
        return root
    }

    // Everything the engine returns for `text`, as (title, kind) pairs.
    // A Set, because BM25 scores on a tiny corpus nearly tie, so order is meaningless.
    private func hits(_ engine: SQLiteSearchEngine, _ text: String) async throws -> Set<String> {
        let results = try await engine.search(SearchQuery(text: text))
        return Set(results.map { "\($0.title) (\($0.kind.rawValue))" })
    }

    @Test func indexesFilesFoldersAndAppsWithTheRightKind() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try SQLiteSearchEngine(path: ":memory:")

        await FileCrawler(roots: [root]).crawl(into: engine)

        #expect(try await hits(engine, "notes") == ["Notes.md (file)"])
        #expect(try await hits(engine, "projects") == ["Projects (folder)"])
        #expect(try await hits(engine, "calculator") == ["Calculator (app)"])
    }

    @Test func skipsJunkFoldersHiddenFilesAndAppInsides() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try SQLiteSearchEngine(path: ":memory:")

        await FileCrawler(roots: [root]).crawl(into: engine)

        #expect(try await hits(engine, "lodash").isEmpty)
        #expect(try await hits(engine, "node_modules").isEmpty)
        #expect(try await hits(engine, "secret").isEmpty)
        #expect(try await hits(engine, "info").isEmpty)
    }

    @Test func recrawlRemovesDeletedFiles() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try SQLiteSearchEngine(path: ":memory:")
        let crawler = FileCrawler(roots: [root])

        await crawler.crawl(into: engine)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Notes.md"))
        await crawler.crawl(into: engine)

        #expect(try await hits(engine, "notes").isEmpty)
        #expect(try await hits(engine, "projects") == ["Projects (folder)"])
    }

    @Test func pruneOnlyTouchesItsOwnRoot() async throws {
        let engine = try SQLiteSearchEngine(path: ":memory:")
        // "/a/b" must not be treated as containing "/a/bc/...".
        try await engine.upsert([
            IndexedFile(path: "/a/b/old.txt", name: "old.txt"),
            IndexedFile(path: "/a/bc/keep.txt", name: "keep.txt"),
        ], indexedAt: 1)

        try await engine.prune(under: "/a/b", olderThan: 2)

        #expect(try await hits(engine, "old").isEmpty)
        #expect(try await hits(engine, "keep") == ["keep.txt (file)"])
    }

    @Test func camelCaseNamesMatchTheirParts() async throws {
        let engine = try SQLiteSearchEngine(path: ":memory:")
        try await engine.upsert(path: "/src/SearchPanel.swift", name: "SearchPanel.swift")

        #expect(try await hits(engine, "panel") == ["SearchPanel.swift (file)"])
    }
}

@Suite struct KindFilterTests {
    @Test func onlyReturnsRequestedKinds() async throws {
        let engine = try SQLiteSearchEngine(path: ":memory:")
        try await engine.upsert(path: "/Applications/Safari.app", name: "Safari", kind: .app)
        try await engine.upsert(path: "/docs/safari-notes.md", name: "safari-notes.md")

        let apps = try await engine.search(SearchQuery(text: "saf", kinds: [.app]))
        let files = try await engine.search(SearchQuery(text: "saf", kinds: [.file, .folder]))

        #expect(apps.map(\.title) == ["Safari"])
        #expect(files.map(\.title) == ["safari-notes.md"])
    }
}
