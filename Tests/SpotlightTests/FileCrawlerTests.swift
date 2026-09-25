import Foundation
import Testing

@testable import Spotlight

@Suite struct FileCrawlerTests {
    // A small fake tree:
    //
    //   Notes.md                              file
    //   Projects/                             folder
    //   Projects/node_modules/lodash.js       skipped (junk folder)
    //   .secret.txt                           skipped (hidden)
    //   Calculator.app/Contents/Info.plist    app; its insides are skipped
    private func makeTree() throws -> TemporaryFolder {
        let folder = try TemporaryFolder()
        for file in [
            "Notes.md", "Projects/node_modules/lodash.js", ".secret.txt",
            "Calculator.app/Contents/Info.plist",
        ] {
            try folder.write("hello", to: file)
        }
        return folder
    }

    // Everything the engine returns for `text`, as "title (kind)".
    private func hits(_ engine: SQLiteSearchEngine, _ text: String) async throws -> Set<String> {
        let results = try await engine.search(SearchQuery(text: text))
        return Set(results.map { "\($0.title) (\($0.kind.rawValue))" })
    }

    @Test func indexesFilesFoldersAndAppsWithTheRightKind() async throws {
        let folder = try makeTree()
        defer { folder.delete() }
        let engine = try makeEngine()

        await FileCrawler(roots: [folder.url]).crawl(into: engine)

        #expect(try await hits(engine, "notes") == ["Notes.md (file)"])
        #expect(try await hits(engine, "projects") == ["Projects (folder)"])
        // Apps drop ".app"; files keep their extension.
        #expect(try await hits(engine, "calculator") == ["Calculator (app)"])
    }

    @Test func skipsJunkFoldersHiddenFilesAndAppInsides() async throws {
        let folder = try makeTree()
        defer { folder.delete() }
        let engine = try makeEngine()

        await FileCrawler(roots: [folder.url]).crawl(into: engine)

        #expect(try await engine.titles(for: "lodash").isEmpty)
        #expect(try await engine.titles(for: "node_modules").isEmpty)
        #expect(try await engine.titles(for: "secret").isEmpty)
        #expect(try await engine.titles(for: "info").isEmpty)
    }

    @Test func recrawlRemovesDeletedFiles() async throws {
        let folder = try makeTree()
        defer { folder.delete() }
        let engine = try makeEngine()
        let crawler = FileCrawler(roots: [folder.url])

        await crawler.crawl(into: engine)
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("Notes.md"))
        await crawler.crawl(into: engine)

        #expect(try await engine.titles(for: "notes").isEmpty)
        // Unchanged items survive the second crawl.
        #expect(try await engine.titles(for: "projects") == ["Projects"])
    }

    @Test func indexesContentOfTextFiles() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        try folder.write("Quarterly budget for the zeppelin project", to: "plan.md")
        try folder.write("export const zeppelinSpeed = 42", to: "speed.ts")
        let engine = try makeEngine()

        await FileCrawler(roots: [folder.url]).crawl(into: engine)

        #expect(try await engine.titles(for: "zeppelin") == ["plan.md", "speed.ts"])
    }

    @Test func nameOnlyRootsSkipContent() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        try folder.write("secret zeppelin plans", to: "readme.txt")
        let engine = try makeEngine()

        await FileCrawler(roots: [], nameOnlyRoots: [folder.url]).crawl(into: engine)

        #expect(try await engine.titles(for: "readme") == ["readme.txt"])
        #expect(try await engine.titles(for: "zeppelin").isEmpty)
    }

    @Test func recrawlRereadsChangedFiles() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let file = try folder.write("alpha", to: "todo.txt")
        let engine = try makeEngine()
        let crawler = FileCrawler(roots: [folder.url])
        await crawler.crawl(into: engine)

        try folder.write("bravo", to: "todo.txt")
        // Make sure the date really moves, even if both writes land in the same instant.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        await crawler.crawl(into: engine)

        #expect(try await engine.titles(for: "alpha").isEmpty)
        #expect(try await engine.titles(for: "bravo") == ["todo.txt"])
    }

    @Test func missingRootIsHarmless() async throws {
        let engine = try makeEngine()
        let missing = URL(fileURLWithPath: "/definitely/not/here-\(UUID().uuidString)")

        await FileCrawler(roots: [missing]).crawl(into: engine)

        #expect(try await engine.stats().itemCount == 0)
    }
}
