import Foundation
import Testing

@testable import Spotlight

@Suite struct TrainingExampleRulesTests {
    private func item(_ position: Int, _ title: String) -> TrainingExample.Item {
        .init(id: "id\(position)", source: "gmail:a", kind: "email", title: title, text: title, position: position)
    }

    private func negatives(chosen: Int, _ titles: [String]) -> [String] {
        let shown = titles.enumerated().map { item($0.offset, $0.element) }
        let example = TrainingExample.make(query: "q", shown: shown, chosenPosition: chosen, ranker: "r", at: Date())
        return example?.negatives.map { "\($0.title):\($0.why ?? "")" } ?? []
    }

    @Test func everythingAboveAndTwoBelow() {
        #expect(negatives(chosen: 2, ["a", "b", "C", "d", "e", "f"])
            == ["a:skipped_above", "b:skipped_above", "d:shown_below", "e:shown_below"])
    }

    @Test func topResultOpenedHasOnlyBelowNegatives() {
        #expect(negatives(chosen: 0, ["A", "b", "c", "d"]) == ["b:shown_below", "c:shown_below"])
    }

    // Two emails in a thread share a subject; one mustn't be a negative for the other.
    @Test func sameTitleIsNeverANegative() {
        #expect(negatives(chosen: 1, ["Re: Lunch", "Lunch", " lunch ", "Dinner"]) == ["Re: Lunch:skipped_above", "Dinner:shown_below"])
    }

    @Test func positiveIsTheOpenedItem() {
        let shown = [item(0, "a"), item(1, "b")]
        let example = TrainingExample.make(query: "q", shown: shown, chosenPosition: 1, ranker: "r", at: Date())

        #expect(example?.positive.title == "b")
        #expect(TrainingExample.make(query: "q", shown: shown, chosenPosition: 7, ranker: "r", at: Date()) == nil)
    }

    @Test func exportIsOneJSONObjectPerLine() throws {
        let example = try #require(TrainingExample.make(
            query: "q", shown: [item(0, "a"), item(1, "b")], chosenPosition: 0, ranker: "r",
            at: Date(timeIntervalSince1970: 0)))

        let lines = String(decoding: try TrainingExample.jsonLines([example, example]), as: UTF8.self)
            .split(separator: "\n")

        #expect(lines.count == 2)
        #expect(lines[0].contains(#""query":"q""#))
        #expect(lines[0].contains(#""at":"1970-01-01T00:00:00Z""#))
        let decoded = try JSONDecoder.withISODates.decode(TrainingExample.self, from: Data(lines[0].utf8))
        #expect(decoded.positive.title == "a")
    }
}

extension JSONDecoder {
    static var withISODates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@Suite struct SelectionLogTests {
    // Indexes three emails and returns what a search for "trip" shows.
    private func searchedEngine() async throws -> (SQLiteSearchEngine, [SearchResult]) {
        let engine = try makeEngine()
        try await engine.upsert([
            IndexedFile(path: "https://m/1", name: "Trip to Lisbon", kind: .email, content: "Flights booked for the conference",
                        detail: "Jane", source: "gmail:a"),
            IndexedFile(path: "https://m/2", name: "Trip ideas", kind: .email, content: "Maybe Japan", source: "gmail:a"),
            IndexedFile(path: "https://m/3", name: "Road trip playlist", kind: .email, content: "Songs", source: "gmail:a"),
        ])
        let shown = try await engine.search(SearchQuery(text: "trip", kinds: [.email]))
        return (engine, shown)
    }

    @Test func recordsWhatWasShownAndOpened() async throws {
        let (engine, shown) = try await searchedEngine()
        let chosen = try #require(shown.firstIndex { $0.title == "Trip to Lisbon" })

        try await engine.recordSelection(query: "trip", shown: shown, chosenIndex: chosen)
        let examples = try await engine.trainingExamples()

        #expect(try await engine.selectionCount() == 1)
        let example = try #require(examples.first)
        #expect(example.query == "trip")
        #expect(example.positive.id == "https://m/1")
        #expect(example.positive.source == "gmail:a")
        // The copy includes the second line and the start of the content.
        #expect(example.positive.text.contains("Jane"))
        #expect(example.positive.text.contains("booked for the conference"))
        #expect(example.ranker == Ranking.version)
        #expect(Set(example.negatives.map(\.id)) == Set(shown.map { $0.subtitle! }).subtracting(["https://m/1"]))
    }

    @Test func examplesOutliveTheItemsTheyMention() async throws {
        let (engine, shown) = try await searchedEngine()
        try await engine.recordSelection(query: "trip", shown: shown, chosenIndex: 0)

        // The emails leave the index (deleted in Gmail, or aged out).
        try await engine.removeAll(from: "gmail:a")

        #expect(try await engine.trainingExamples().count == 1)
    }

    @Test func blankQueriesAndBadIndexesAreIgnored() async throws {
        let (engine, shown) = try await searchedEngine()

        try await engine.recordSelection(query: "  ", shown: shown, chosenIndex: 0)
        try await engine.recordSelection(query: "trip", shown: shown, chosenIndex: 99)

        #expect(try await engine.selectionCount() == 0)
    }

    @Test func clearRemovesEverything() async throws {
        let (engine, shown) = try await searchedEngine()
        try await engine.recordSelection(query: "trip", shown: shown, chosenIndex: 0)

        try await engine.clearSelections()

        #expect(try await engine.selectionCount() == 0)
        #expect(try await engine.trainingExamples().isEmpty)
    }
}
