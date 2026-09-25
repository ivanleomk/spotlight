import Foundation

// Preparing text on its way into and out of the FTS5 index. Pure functions
// (same input, same output, no database), which makes them easy to test.
enum SearchText {
    // Turns what the user typed into a safe FTS5 query: "note app" -> "note"* "app"*
    // Raw input could contain characters FTS5 treats as syntax (quotes, -, :), so we
    // keep only letters and digits, quote each word, and add * so the last word can
    // still be half-typed.
    //
    // Very short queries ("t", "sa") match names only: a one-letter prefix
    // matches most of the index, and scoring all that content made the first
    // keystroke take a third of a second. It's also what you mean when you've
    // typed two letters. Content joins in from the third character.
    // A single character goes further: only names that *start* with it
    // (`^` = the column's first word), a third as many rows as "any word".
    static let nameOnlyMaxCharacters = 2

    static func matchExpression(from text: String) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return nil }
        let characters = words.reduce(0) { $0 + $1.count }
        if characters == 1 { return "name : ^\"\(words[0])\"*" }
        let nameOnly = characters <= nameOnlyMaxCharacters
        // `name : "t"*` is FTS5 for "a word starting with t, in the name column".
        return words.map { (nameOnly ? "name : " : "") + "\"\($0)\"*" }.joined(separator: " ")
    }

    // For one character BM25 says almost nothing (it mostly prefers short
    // names) and scoring ten thousand names costs ~65 ms, so rank by name
    // length directly: ~39 ms. Higher is better, like BM25 scores.
    static func usesNameLengthRanking(_ text: String) -> Bool {
        text.split { !$0.isLetter && !$0.isNumber }.reduce(0) { $0 + $1.count } == 1
    }

    // The index splits words at punctuation ("my-notes.md" -> my, notes, md) but not
    // at camelCase, so "SearchPanel" would be one word and a search for "panel" would
    // miss it. We add a split copy: "SearchPanel" -> "SearchPanel Search Panel".
    static func indexable(_ text: String) -> String {
        var split = ""
        var previous: Character?
        for character in text {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                split.append(" ")
            }
            split.append(character)
            previous = character
        }
        return split == text ? text : text + " " + split
    }

    // MARK: - Snippets

    // What the user typed, as lowercase words without accents: "Café  2024" -> ["cafe", "2024"].
    static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map { fold(String($0)) }
    }

    // Does any word in `text` start with one of `words`? The same rule FTS5
    // uses for a prefix query, so this agrees with what matched. camelCase
    // parts count too ("SearchPanel" matches "panel"), as they do in the index.
    static func matches(_ text: String, words: [String]) -> Bool {
        let tokens = indexable(text).split { !$0.isLetter && !$0.isNumber }.map { fold(String($0)) }
        return tokens.contains { token in words.contains { token.hasPrefix($0) } }
    }

    // A short excerpt of `content` around the first word matching one of
    // `words`, with every matching word wrapped in MatchMarkers; nil if nothing
    // matches. About `length` words long, with "…" where text was cut off.
    static func snippet(of content: String, words: [String], length: Int = 12) -> String? {
        guard !words.isEmpty else { return nil }
        // Where each word in the content starts and ends.
        var tokens: [Range<String.Index>] = []
        var start: String.Index?
        for index in content.indices {
            let isWordCharacter = content[index].isLetter || content[index].isNumber
            if isWordCharacter, start == nil { start = index }
            if !isWordCharacter, let s = start {
                tokens.append(s..<index)
                start = nil
            }
        }
        if let s = start { tokens.append(s..<content.endIndex) }

        func isMatch(_ range: Range<String.Index>) -> Bool {
            let token = fold(String(content[range]))
            return words.contains { token.hasPrefix($0) }
        }
        guard let first = tokens.firstIndex(where: isMatch) else { return nil }

        // A few words of lead-in before the match, then the rest of the window.
        let from = max(0, first - 3)
        let to = min(tokens.count - 1, from + length - 1)
        var snippet = from > 0 ? "…" : ""
        var cursor = tokens[from].lowerBound
        for range in tokens[from...to] where isMatch(range) {
            snippet += content[cursor..<range.lowerBound]
            snippet += String(MatchMarker.start) + content[range] + String(MatchMarker.end)
            cursor = range.upperBound
        }
        snippet += content[cursor..<tokens[to].upperBound]
        if to < tokens.count - 1 { snippet += "…" }
        return snippet
    }

    // Lowercase and without accents, matching the index's `remove_diacritics`.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
