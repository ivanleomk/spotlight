import Foundation

// One training example for search: a query, the result you opened, and
// results you passed over. Built from the selection log when exporting.
struct TrainingExample: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var id: String      // path or web link; stable off this Mac
        var source: String  // "files", "gmail:me@x.com", ...
        var kind: String
        var title: String
        var text: String    // title, second line, start of the content
        var position: Int   // 0 = top of the panel
        var why: String?    // for negatives: "skipped_above" or "shown_below"
    }

    var query: String
    var positive: Item
    var negatives: [Item]
    var ranker: String
    var at: Date

    // How many results just below the opened one count as negatives. Beyond
    // that, you probably never looked.
    static let belowWindow = 2

    // The rules for picking negatives, all in one place:
    //   - everything above the opened result was seen and passed over (strong);
    //   - the next `belowWindow` results below it (weaker; tagged so training
    //     can weight them less);
    //   - never anything that looks like the same item (same title), which
    //     would teach the model that the right answer is wrong.
    static func make(
        query: String, shown: [Item], chosenPosition: Int, ranker: String, at: Date
    ) -> TrainingExample? {
        guard let positive = shown.first(where: { $0.position == chosenPosition }) else { return nil }
        let sameTitle = normalized(positive.title)
        var negatives: [Item] = []
        for item in shown.sorted(by: { $0.position < $1.position }) {
            guard item.position != chosenPosition, item.id != positive.id, normalized(item.title) != sameTitle
            else { continue }
            var negative = item
            if item.position < chosenPosition {
                negative.why = "skipped_above"
            } else if item.position <= chosenPosition + belowWindow {
                negative.why = "shown_below"
            } else {
                continue
            }
            negatives.append(negative)
        }
        return TrainingExample(query: query, positive: positive, negatives: negatives, ranker: ranker, at: at)
    }

    private static func normalized(_ title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespaces)
    }

    // JSON Lines: one example per line, the usual format for training data.
    static func jsonLines(_ examples: [TrainingExample]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for example in examples {
            out.append(try encoder.encode(example))
            out.append(0x0A)  // newline
        }
        return out
    }
}
