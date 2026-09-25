import Foundation
import Testing

@testable import Spotlight

@Suite struct ShortQueryTests {
    @Test func oneOrTwoLettersMatchNamesOnly() {
        #expect(SearchText.matchExpression(from: "t") == #"name : ^"t"*"#)
        #expect(SearchText.matchExpression(from: "sa") == #"name : "sa"*"#)
        #expect(SearchText.matchExpression(from: "a b") == #"name : "a"* name : "b"*"#)
        #expect(SearchText.matchExpression(from: "tri") == #""tri"*"#)
    }

    @Test func oneLetterMatchesNamesStartingWithItShortestFirst() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/Road trip.md", name: "Road trip.md")
        try await engine.upsert(path: "/a/Telegram notes.md", name: "Telegram notes.md")
        try await engine.upsert(path: "/a/Tips.md", name: "Tips.md")

        let results = try await engine.search(SearchQuery(text: "t"))

        #expect(results.map(\.title) == ["Tips.md", "Telegram notes.md"])
    }

    @Test func shortQueriesIgnoreContent() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/Safari notes.md", name: "Safari notes.md")
        try await engine.upsert(path: "/a/other.md", name: "other.md", content: "safari trip")

        #expect(try await engine.titles(for: "sa") == ["Safari notes.md"])
        #expect(try await engine.titles(for: "saf") == ["Safari notes.md", "other.md"])
    }
}

@Suite struct BatchedSearchTests {
    private func filledEngine() async throws -> SQLiteSearchEngine {
        let engine = try makeEngine()
        var files: [IndexedFile] = []
        for i in 0..<8 {
            files.append(IndexedFile(path: "/Applications/Plan\(i).app", name: "Plan \(i)", kind: .app))
            files.append(IndexedFile(path: "https://m/\(i)", name: "Plan email \(i)", kind: .email, modifiedAt: Double(i)))
            files.append(IndexedFile(path: "/docs/plan\(i).md", name: "plan\(i).md", kind: .file))
        }
        try await engine.upsert(files)
        return engine
    }

    // Ranking every section in one pass must give the same answer as asking
    // one section at a time.
    @Test func sameResultsAsOneSectionAtATime() async throws {
        let engine = try await filledEngine()
        let queries = ResultSection.Group.all.map { SearchQuery(text: "plan", limit: $0.limit, kinds: $0.kinds) }

        let batched = try await engine.search(queries)
        var separately: [[SearchResult]] = []
        for query in queries { separately.append(try await engine.search(query)) }

        #expect(batched.map { $0.map(\.id) } == separately.map { $0.map(\.id) })
        #expect(batched[0].count == 3)  // apps, capped at the section's limit
        #expect(batched[0].allSatisfy { $0.kind == .app })
    }

    @Test func anyKindQueryStillFindsTheBestOverall() async throws {
        let engine = try await filledEngine()

        let results = try await engine.search(SearchQuery(text: "plan", limit: 30))

        #expect(results.count == 24)
        #expect(Set(results.map(\.kind)) == [.app, .email, .file])
    }

    @Test func snippetsStillAppearForContentMatches() async throws {
        let engine = try makeEngine()
        try await engine.upsert(path: "/a/notes.md", name: "notes.md", content: "buy oat milk")

        let result = try #require(try await engine.search(SearchQuery(text: "oat")).first)

        #expect(result.snippet == "buy \u{2}oat\u{3} milk")
    }

    @Test func cancelledSearchesStopEarly() async throws {
        let engine = try await filledEngine()
        let task = Task { try await engine.search([SearchQuery(text: "plan")]) }
        task.cancel()

        // Either it finished before noticing, or it stopped and returned nothing.
        let results = try await task.value
        #expect(results.count == 1)
    }
}

@Suite struct SearchReaderTests {
    // The reader has its own connection, so it must see what the engine wrote,
    // including rows written after the reader was opened.
    @Test func seesTheEnginesWritesOnItsOwnConnection() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let path = folder.url.appendingPathComponent("index.sqlite").path
        let engine = try SQLiteSearchEngine(path: path)
        let reader = try SearchReader(path: path)

        try await engine.upsert(path: "/a/zeppelin.md", name: "zeppelin.md")
        let results = try await reader.search(SearchQuery(text: "zep"))

        #expect(results.map(\.title) == ["zeppelin.md"])
    }

    @Test func refusesToWrite() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let path = folder.url.appendingPathComponent("index.sqlite").path
        _ = try SQLiteSearchEngine(path: path)
        let db = try SQLiteConnection(path: path)
        try db.execute("PRAGMA query_only = ON")

        #expect(throws: SQLiteError.self) { try db.execute("DELETE FROM documents") }
    }

    // Searching while a big write is in progress must not wait for it.
    @Test func searchesDuringALongWrite() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let path = folder.url.appendingPathComponent("index.sqlite").path
        let engine = try SQLiteSearchEngine(path: path)
        try await engine.upsert(path: "/a/early.md", name: "early.md")
        let reader = try SearchReader(path: path)

        let files = (0..<3000).map { IndexedFile(path: "/bulk/\($0).txt", name: "bulk \($0)", content: "filler text") }
        async let write: Void = engine.upsert(files)
        let found = try await reader.search(SearchQuery(text: "early"))
        try await write

        #expect(found.map(\.title) == ["early.md"])
    }
}
