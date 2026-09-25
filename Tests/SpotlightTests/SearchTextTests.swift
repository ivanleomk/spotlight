import Testing

@testable import Spotlight

@Suite struct MatchExpressionTests {
    @Test func quotesEachWordAndAllowsPrefixes() {
        #expect(SearchText.matchExpression(from: "note app") == #""note"* "app"*"#)
    }

    @Test func splitsOnPunctuation() {
        #expect(SearchText.matchExpression(from: "my-notes.md") == #""my"* "notes"* "md"*"#)
    }

    @Test func keepsAccentedLettersAndDigits() {
        #expect(SearchText.matchExpression(from: "café 2024") == #""café"* "2024"*"#)
    }

    // Arguments run the same test once per value.
    @Test(arguments: ["", "   ", #"  -:"* "#])
    func returnsNilWhenThereAreNoWords(_ text: String) {
        #expect(SearchText.matchExpression(from: text) == nil)
    }
}

@Suite struct IndexableTextTests {
    @Test func addsCamelCaseParts() {
        #expect(SearchText.indexable("SearchPanel") == "SearchPanel Search Panel")
        #expect(SearchText.indexable("parseJSON") == "parseJSON parse JSON")
    }

    @Test func splitsAfterDigits() {
        #expect(SearchText.indexable("v2Engine") == "v2Engine v2 Engine")
    }

    @Test func leavesPlainTextAlone() {
        #expect(SearchText.indexable("notes.md") == "notes.md")
        #expect(SearchText.indexable("") == "")
    }

    // A known limitation, written down as a test: runs of capitals aren't split.
    @Test func doesNotSplitAcronymRuns() {
        #expect(SearchText.indexable("HTTPServer") == "HTTPServer")
    }
}
