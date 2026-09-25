import Foundation

@testable import Spotlight

// A fresh, empty folder for one test. Call `delete()` in a `defer` so it's
// cleaned up however the test ends.
struct TemporaryFolder {
    let url: URL

    init() throws {
        // Under /var/folders/..., which is a symlink to /private/var/..., so every
        // crawler test also checks that symlinked roots work.
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotlightTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Writes a file (creating any folders on the way) and returns its URL.
    @discardableResult
    func write(_ text: String, to relativePath: String) throws -> URL {
        try write(Data(text.utf8), to: relativePath)
    }

    @discardableResult
    func write(_ data: Data, to relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

// A throwaway in-memory index, so tests never touch your real one.
func makeEngine() throws -> SQLiteSearchEngine {
    try SQLiteSearchEngine(path: ":memory:")
}

extension SQLiteSearchEngine {
    // Titles of the results as a Set: on tiny test indexes BM25 scores nearly
    // tie, so the order isn't meaningful and tests shouldn't depend on it.
    func titles(for text: String, kinds: [DocumentKind] = []) async throws -> Set<String> {
        Set(try await search(SearchQuery(text: text, kinds: kinds)).map(\.title))
    }
}
