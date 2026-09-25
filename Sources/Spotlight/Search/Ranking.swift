import Foundation

// Reorders search results so recent things float up, differently per kind:
//
//   final score = text score (BM25) × (1 + weight × ½^(age / half-life))
//
// So a brand-new email gets up to (1 + weight)× its text score, and the extra
// halves every `halfLife`. Old items never drop below their plain text score;
// they just stop getting a boost. Local files and apps get no boost at all.
enum Ranking {
    // Recorded with every selection, so training data says which ordering
    // people were choosing from. Bump it whenever ranking changes.
    static let version = "bm25+recency-v1"

    // How many BM25 candidates to fetch per result we show, so recency has
    // something to choose from.
    static let candidateMultiplier = 4

    struct Recency: Equatable {
        var weight: Double
        var halfLife: TimeInterval
        // Calendar: distance from now in either direction, so tomorrow's
        // meeting counts as "recent" just like yesterday's.
        var measuresDistanceFromNow = false
    }

    static let day: TimeInterval = 24 * 60 * 60

    static func recency(for kind: DocumentKind) -> Recency? {
        switch kind {
        case .email: Recency(weight: 1.5, halfLife: 30 * day)
        case .event: Recency(weight: 2.0, halfLife: 7 * day, measuresDistanceFromNow: true)
        case .driveFile: Recency(weight: 1.0, halfLife: 45 * day)
        case .file, .folder, .app: nil
        }
    }

    // How much recency multiplies the text score: 1 means no boost.
    static func boost(for kind: DocumentKind, date: Date?, now: Date) -> Double {
        guard let recency = recency(for: kind), let date else { return 1 }
        var age = now.timeIntervalSince(date)
        if recency.measuresDistanceFromNow {
            age = abs(age)
        } else {
            age = max(age, 0)  // a date in the future (clock skew) counts as brand new
        }
        return 1 + recency.weight * pow(0.5, age / recency.halfLife)
    }

    static func rerank(_ results: [SearchResult], now: Date) -> [SearchResult] {
        results
            .map { result in
                var ranked = result
                ranked.score = result.score * boost(for: result.kind, date: result.date, now: now)
                return ranked
            }
            // Stable for ties: equal scores keep BM25's order.
            .enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
    }
}
