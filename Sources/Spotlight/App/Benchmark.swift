import Foundation

// Times the search panel's exact search (every section at once) against the
// real index. Run with `make bench`.
enum Benchmark {
    static func run(_ texts: [String], repeats: Int = 5) async {
        guard let path = try? SQLiteSearchEngine.defaultDatabasePath(),
            let reader = try? SearchReader(path: path)
        else { return print("Could not open the index") }
        let groups = ResultSection.Group.all
        for text in texts {
            let queries = groups.map { SearchQuery(text: text, limit: $0.limit, kinds: $0.kinds) }
            var times: [Duration] = []
            var rows = 0
            for _ in 0..<repeats {
                let started = ContinuousClock.now
                rows = ((try? await reader.search(queries)) ?? []).reduce(0) { $0 + $1.count }
                times.append(ContinuousClock.now - started)
            }
            let best = times.min()!, median = times.sorted()[times.count / 2]
            print("\"\(text)\"".padding(toLength: 10, withPad: " ", startingAt: 0),
                  "median \(ms(median)) ms, best \(ms(best)) ms, \(rows) rows")
        }
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%6.1f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }
}
