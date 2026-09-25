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
        case .email: "Email"
        case .event: "Event"
        case .driveFile: "Drive"
        }
    }

    // What Return does to a result of this kind, shown in the panel's footer.
    var openActionName: String {
        switch self {
        case .email: "Open in Gmail"
        case .event: "Open in Calendar"
        case .driveFile: "Open in Drive"
        default: "Open \(displayName)"
        }
    }

    // An SF Symbol to use when there's no real Finder icon.
    var symbolName: String {
        switch self {
        case .app: "app.dashed"
        case .folder: "folder"
        case .file: "doc"
        case .email: "envelope.fill"
        case .event: "calendar"
        case .driveFile: "doc.richtext"
        }
    }
}

extension DocumentKind {
    // Things on this Mac (with a file path), as opposed to things from Google.
    var isLocal: Bool { self == .file || self == .folder || self == .app }

    var tint: Color {
        switch self {
        case .email: .blue
        case .event: .red
        case .driveFile: .green
        default: .secondary
        }
    }
}

// The grey text after a result's name, by kind:
//   file     ~/Documents/coding            (the folder it's in)
//   email    Jane Doe · 3 days ago         (sender, when it arrived)
//   event    Tue 30 Sep, 14:00 · Room 4    (when it starts, where)
//   drive    You · 2 days ago              (owner, last edited or opened)
enum ResultText {
    static func secondary(for result: SearchResult, now: Date) -> String? {
        switch result.kind {
        case .app:
            return nil
        case .file, .folder:
            return result.subtitle.map { PathDisplay.parentFolder(of: $0) }
        case .email, .driveFile:
            return join(result.detail, result.date.map { relative($0, now: now) })
        case .event:
            return join(result.date.map { eventTime($0, now: now) }, result.detail)
        }
    }

    // "3 days ago", "in 2 hours"
    static func relative(_ date: Date, now: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "en_US")))
            .replacingOccurrences(of: "in 0 seconds", with: "now")
    }

    // "Tue 30 Sep, 14:00", with the year only when it isn't this year.
    static func eventTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let base = Date.FormatStyle(locale: Locale(identifier: "en_GB"), calendar: calendar, timeZone: calendar.timeZone)
        // Day and time formatted separately: together, the formatter would write
        // "Wed 30 Sep at 14:00".
        var day = base.weekday(.abbreviated).day().month(.abbreviated)
        if !sameYear { day = day.year() }
        return date.formatted(day) + ", " + date.formatted(base.hour().minute())
    }

    private static func join(_ parts: String?...) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " · ")
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
