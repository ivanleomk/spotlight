import SwiftUI

// How things are named and shown on screen. Kept out of the views so the
// search panel and Settings agree, and so tests can check them directly.

extension DocumentKind {
    // "Application", shown on the right of each result.
    var displayName: String {
        switch self {
        case .app: "Application"
        case .folder: "Folder"
        case .file: "File"
        }
    }

    // What Return does to a result of this kind, shown in the panel's footer.
    var openActionName: String { "Open \(displayName)" }

    // An SF Symbol to use when there's no real Finder icon.
    var symbolName: String {
        switch self {
        case .app: "app.dashed"
        case .folder: "folder"
        case .file: "doc"
        }
    }
}

enum PathDisplay {
    // "/Users/ivan/Documents/x.pdf" -> "~/Documents/x.pdf". Only a whole leading
    // home folder counts: "/Users/ivan2/x" is someone else's folder.
    static func abbreviatingHome(
        _ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // The folder an item sits in, e.g. "~/Documents/coding" for a file inside it.
    static func parentFolder(
        of path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        abbreviatingHome((path as NSString).deletingLastPathComponent, home: home)
    }
}

// FTS5 marks matched words in names and snippets by wrapping them in two
// invisible control characters, which we choose in the SQL (char(2), char(3)).
enum MatchMarker {
    static let start: Character = "\u{2}"
    static let end: Character = "\u{3}"

    // Turns "one \u{2}match\u{3} two" into styled text with "match" in bold.
    // AttributedString is a string where each stretch of characters can carry
    // its own styling (font, color, ...).
    static func attributed(_ marked: String, size: CGFloat = 12) -> AttributedString {
        // Snippets can span lines; a one-line row wants them flattened.
        let flat = marked.replacing(/\s+/, with: " ")
        var result = AttributedString()
        // Split at each start marker. Every piece after the first begins with a match,
        // which runs until the end marker.
        for (index, piece) in flat.split(separator: start, omittingEmptySubsequences: false).enumerated() {
            guard index > 0, let endIndex = piece.firstIndex(of: end) else {
                result += AttributedString(String(piece))
                continue
            }
            var match = AttributedString(String(piece[..<endIndex]))
            match.font = .system(size: size, weight: .semibold)
            match.foregroundColor = .primary
            result += match
            result += AttributedString(String(piece[piece.index(after: endIndex)...]))
        }
        return result
    }
}
