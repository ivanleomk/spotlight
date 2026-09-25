import Foundation

// Everything the UI needs to ask for. A struct with defaults means we can add
// fields later (folder scope, file types, ...) without breaking existing callers.
struct SearchQuery: Sendable {
    var text: String
    var limit: Int = 20
}

// What sort of thing an indexed item is. An enum is a type with a fixed set of
// cases; `: String` gives each case a text form ("file", "folder", "app") that
// we store in the database.
enum DocumentKind: String, Sendable {
    case file, folder, app
}

// One search hit. Identifiable = "has a stable `id`", which SwiftUI needs to
// tell list rows apart.
struct SearchResult: Identifiable, Sendable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var kind: DocumentKind = .file
    var score: Double = 0
}

// A protocol is a contract: "anything that has these methods counts as a
// SearchEngine". The UI only knows about this contract, so we can swap the
// implementation (fake now, SQLite FTS5 later) without touching the UI.
//
// Sendable = safe to share across threads/tasks, which async code requires.
protocol SearchEngine: Sendable {
    // `async` = may take a while and suspend without blocking the UI.
    // `throws` = may fail (e.g. a database error).
    func search(_ query: SearchQuery) async throws -> [SearchResult]
}
