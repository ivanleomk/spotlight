import Foundation

// Everything the UI needs to ask for. A struct with defaults means we can add
// fields later (folder scope, file types, ...) without breaking existing callers.
struct SearchQuery: Sendable {
    var text: String
    var limit: Int = 20
    // Only return these kinds. Empty means "any kind".
    var kinds: [DocumentKind] = []
}

// What sort of thing an indexed item is. An enum is a type with a fixed set of
// cases; `: String` gives each case a text form ("file", "folder", "app") that
// we store in the database.
enum DocumentKind: String, Sendable, CaseIterable {
    case file, folder, app
    // From Google: a Gmail message, a Calendar event, a Drive file.
    case email, event
    case driveFile = "drive_file"
}

extension SearchResult {
    // Where Return takes you: a web page for Google items, a file otherwise.
    var openURL: URL? {
        guard let subtitle else { return nil }
        if subtitle.hasPrefix("https://") { return URL(string: subtitle) }
        return URL(fileURLWithPath: subtitle)
    }
}

// One search hit. Identifiable = "has a stable `id`", which SwiftUI needs to
// tell list rows apart.
struct SearchResult: Identifiable, Sendable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var kind: DocumentKind = .file
    var score: Double = 0
    // A short second line from the source: an email's sender, an event's
    // location, a Drive file's owner.
    var detail: String? = nil
    // When it happened: modified (files), received (email), starts (events),
    // last edited or opened (Drive).
    var date: Date? = nil
    // An excerpt of the file's content around the match, with each matched word
    // wrapped in \u{2}...\u{3}. Nil when the match was in the name or path.
    var snippet: String? = nil
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
