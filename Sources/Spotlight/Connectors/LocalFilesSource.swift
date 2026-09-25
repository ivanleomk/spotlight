import Foundation

// The folders on this Mac, walked by the FileCrawler.
struct LocalFilesSource: Source {
    static let sourceID = "files"

    let folders: [IndexedFolder]

    var id: String { Self.sourceID }
    var displayName: String { "Local Files" }

    func sync(into index: SQLiteSearchEngine, since cursor: String?) async throws -> String? {
        let crawler = FileCrawler(
            roots: folders.filter(\.readsContent).map(\.url),
            nameOnlyRoots: folders.filter { !$0.readsContent }.map(\.url))
        await crawler.crawl(into: index)
        // No cursor: the disk has no "what changed since" log we can ask, so every
        // crawl looks at everything (and skips unchanged files by modification date).
        return nil
    }
}
