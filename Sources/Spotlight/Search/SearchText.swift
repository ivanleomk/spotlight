import Foundation

// Preparing text on its way into and out of the FTS5 index. Pure functions
// (same input, same output, no database), which makes them easy to test.
enum SearchText {
    // Turns what the user typed into a safe FTS5 query: "note app" -> "note"* "app"*
    // Raw input could contain characters FTS5 treats as syntax (quotes, -, :), so we
    // keep only letters and digits, quote each word, and add * so the last word can
    // still be half-typed.
    static func matchExpression(from text: String) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
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
}
