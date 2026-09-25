import Foundation
import Testing

@testable import Spotlight

@Suite struct IndexedFolderTests {
    @Test func homeFoldersAreReadInFullAndAppFoldersByNameOnly() {
        let folders = IndexedFolder.all

        #expect(folders.filter(\.readsContent).map(\.url) == FileCrawler.defaultFolders)
        #expect(folders.filter { !$0.readsContent }.map(\.url) == FileCrawler.applicationRoots)
    }
}

@Suite struct SettingsPageTests {
    @Test func sidebarOrder() {
        #expect(SettingsPage.allCases == [.general, .sources])
    }
}

@Suite struct IndexOverviewTests {
    @Test func loadsTotalsPerFolderCountsAndSize() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let docs = folder.url.appendingPathComponent("Docs")
        try folder.write("a", to: "Docs/one.txt")
        try folder.write("b", to: "Docs/two.txt")
        let databasePath = folder.url.appendingPathComponent("index.sqlite").path
        let engine = try SQLiteSearchEngine(path: databasePath)
        await FileCrawler(roots: [docs]).crawl(into: engine)

        let overview = await IndexOverview.load(
            from: engine, folders: [IndexedFolder(url: docs, readsContent: true)],
            databasePath: databasePath)

        // The counts look up the real (/private/var/...) path of the symlinked temp folder.
        #expect(overview.counts[docs] == 2)
        #expect(overview.stats.itemCount == 2)
        #expect(overview.stats.lastIndexed != nil)
        #expect(overview.sizeInBytes > 0)
    }
}
