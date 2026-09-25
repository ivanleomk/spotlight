import Foundation

// The search itself, shared by the engine (tests, and the app's writer) and the
// read-only SearchReader the panel uses.
//
// Two steps, because FTS5's snippet() is expensive and we only show ~17 rows:
//   1. One ranking pass for every section at once: score each match with BM25
//      and keep the top few *per kind* (a SQL window function), with only
//      cheap columns. Then re-rank by recency and trim each section in Swift.
//   2. For just the rows that will be shown, read their text by row id and
//      cut a snippet around the first matching word (SearchText.snippet).
extension SQLiteSearchEngine {
    static func runSearch(_ queries: [SearchQuery], on db: SQLiteConnection, now: Date) throws -> [[SearchResult]] {
        let empty = queries.map { _ in [SearchResult]() }
        // Everything in one batch searches the same text (the panel's sections).
        guard !Task.isCancelled, let text = queries.first?.text,
            let match = SearchText.matchExpression(from: text)
        else { return empty }

        // Which kinds any section wants, and how many candidates each kind needs.
        // The top N overall is always inside the top N of each kind, so a query
        // for "any kind" is answered from the same per-kind lists.
        let kinds = Set(queries.flatMap { $0.kinds.isEmpty ? DocumentKind.allCases : $0.kinds })
        let perKind = (queries.map(\.limit).max() ?? 0) * Ranking.candidateMultiplier

        let score = SearchText.usesNameLengthRanking(text)
            ? "100.0 / (length(d.name) + 1)"
            : "-bm25(documents_fts, 10.0, 2.0, 1.0)"

        var candidates: [SearchResult] = []
        try db.query(
            """
            SELECT id, name, path, kind, score, detail, modified_at FROM (
              SELECT *, ROW_NUMBER() OVER (PARTITION BY kind ORDER BY score DESC) AS n FROM (
                SELECT d.id, d.name, d.path, d.kind, d.detail, d.modified_at, \(score) AS score
                FROM documents_fts JOIN documents d ON d.id = documents_fts.rowid
                WHERE documents_fts MATCH ? AND d.kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))
              )
            ) WHERE n <= ?
            """,
            [.text(match)] + kinds.sorted(by: { $0.rawValue < $1.rawValue }).map { .text($0.rawValue) } + [.int(Int64(perKind))]
        ) { row in
            let detail = row.string(5)
            let modified = row.double(6)
            candidates.append(
                SearchResult(
                    id: String(row.int(0)), title: row.string(1), subtitle: row.string(2),
                    kind: DocumentKind(rawValue: row.string(3)) ?? .file, score: row.double(4),
                    detail: detail.isEmpty ? nil : detail,
                    date: modified > 0 ? Date(timeIntervalSince1970: modified) : nil))
        }
        guard !Task.isCancelled else { return empty }

        // Each section: its kinds, re-ranked by recency, trimmed to its limit.
        let ranked = Ranking.rerank(candidates, now: now)
        var sections = queries.map { query in
            Array(ranked.filter { query.kinds.isEmpty || query.kinds.contains($0.kind) }.prefix(query.limit))
        }

        // Step 2: snippets for the shown rows only, built in Swift from each
        // row's stored text. (FTS5's snippet() re-runs the match for every row,
        // and a one-letter prefix expands to thousands of words: 15 ms a row.)
        let words = SearchText.words(text)
        for s in sections.indices {
            for r in sections[s].indices {
                let row = sections[s][r]
                guard !SearchText.matches(row.title, words: words), let rowID = Int64(row.id) else { continue }
                var content = ""
                try db.query(
                    "SELECT substr(content, 1, 20000) FROM documents_fts WHERE rowid = ?", [.int(rowID)]
                ) { content = $0.string(0) }
                sections[s][r].snippet = SearchText.snippet(of: content, words: words)
            }
        }
        return sections
    }
}
