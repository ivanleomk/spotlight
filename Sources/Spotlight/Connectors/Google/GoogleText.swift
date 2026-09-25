import Foundation

// Turning what Google sends (base64 bodies, HTML, quoted replies) into plain
// text worth indexing.
enum GoogleText {
    // How much of each email body or document to index (see the size estimates).
    static let maxCharacters = 5_000

    // Gmail and Drive use "URL-safe" base64 (- and _ instead of + and /, no padding).
    static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // Crude but effective for indexing: drop <style>/<script> blocks and tags,
    // decode the common entities.
    static func stripHTML(_ html: String) -> String {
        var text = html.replacing(/(?is)<(style|script)[^>]*>.*?<\/\1>/, with: " ")
        text = text.replacing(/(?i)<br\s*\/?>|<\/p>|<\/div>|<\/tr>/, with: "\n")
        text = text.replacing(/<[^>]+>/, with: " ")
        for (entity, character) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    // Replies repeat the whole thread underneath; indexing that again for every
    // message would bloat the index and make old text match new emails. Cut at
    // "On <date>, <someone> wrote:" and drop "> quoted" lines.
    static func removeQuotedReply(_ text: String) -> String {
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:") { break }
            if trimmed.hasPrefix("-----Original Message-----") { break }
            if trimmed.hasPrefix(">") { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    // Squashes runs of spaces and blank lines, then keeps the first `limit` characters.
    static func tidy(_ text: String, limit: Int = maxCharacters) -> String {
        let collapsed = text.replacing(/[ \t\r\f]+/, with: " ").replacing(/\n\s*\n+/, with: "\n")
        return String(collapsed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    // Google timestamps: "2026-09-30T14:00:00+08:00" (Calendar) or
    // "2026-09-30T06:00:00.123Z" (Drive). Swift's default ISO 8601 parser rejects
    // the fractional seconds, so try with them first, then without.
    static func date(fromISO8601 string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: .iso8601))
    }

    // "Jane Doe <jane@x.com>" -> "Jane Doe"; "jane@x.com" -> "jane@x.com".
    static func displayName(fromAddress address: String) -> String {
        guard let angle = address.firstIndex(of: "<") else { return address.trimmingCharacters(in: .whitespaces) }
        let name = address[..<angle].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !name.isEmpty { return name }
        return address[angle...].trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }
}
