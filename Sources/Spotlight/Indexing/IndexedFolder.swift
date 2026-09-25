import Foundation

// One folder the crawler walks, and whether it reads what's inside the files.
struct IndexedFolder: Identifiable, Sendable {
    let url: URL
    let readsContent: Bool
    var id: URL { url }

    // Everything the app indexes. The crawler and the Settings page both read
    // this list, so what Settings shows is always what actually gets crawled.
    static var all: [IndexedFolder] {
        FileCrawler.defaultFolders.map { IndexedFolder(url: $0, readsContent: true) }
            + FileCrawler.applicationRoots.map { IndexedFolder(url: $0, readsContent: false) }
    }
}
