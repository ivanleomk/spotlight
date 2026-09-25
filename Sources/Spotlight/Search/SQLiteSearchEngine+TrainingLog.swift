import Foundation

// Recording what you open, for training better search later. Everything stays
// in the local database; exporting is something you do by hand in Settings.
extension SQLiteSearchEngine {
    // How much of each result's content is copied into the log.
    static let snapshotCharacters = 500

    // Called when you open a result: logs the query, everything that was on
    // screen (top to bottom), and which one you picked.
    func recordSelection(
        query: String, shown: [SearchResult], chosenIndex: Int,
        ranker: String = Ranking.version, at: Date = Date()
    ) throws {
        guard shown.indices.contains(chosenIndex), !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let snapshots = try snapshots(ids: shown.map(\.id))
        try inTransaction {
            var selectionID: Int64 = 0
            try db.query(
                "INSERT INTO selections(query, at, ranker, chosen_position) VALUES(?, ?, ?, ?) RETURNING id",
                [.text(query), .double(at.timeIntervalSince1970), .text(ranker), .int(Int64(chosenIndex))]
            ) { selectionID = $0.int(0) }

            for (position, result) in shown.enumerated() {
                let snapshot = snapshots[result.id]
                let text = [result.title, result.detail ?? "", snapshot?.content ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                try db.query(
                    """
                    INSERT INTO impressions(selection_id, position, doc_id, source, kind, title, text, score)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int(selectionID), .int(Int64(position)), .text(result.subtitle ?? result.id),
                        .text(snapshot?.source ?? ""), .text(result.kind.rawValue), .text(result.title),
                        .text(text), .double(result.score),
                    ])
            }
        }
    }

    func selectionCount() throws -> Int {
        var count = 0
        try db.query("SELECT count(*) FROM selections") { count = Int($0.int(0)) }
        return count
    }

    func clearSelections() throws {
        try inTransaction {
            try db.execute("DELETE FROM impressions; DELETE FROM selections;")
        }
    }

    // Every logged selection as a training example, oldest first.
    func trainingExamples() throws -> [TrainingExample] {
        var selections: [(id: Int64, query: String, at: Double, ranker: String, chosen: Int)] = []
        try db.query("SELECT id, query, at, ranker, chosen_position FROM selections ORDER BY at, id") { row in
            selections.append((row.int(0), row.string(1), row.double(2), row.string(3), Int(row.int(4))))
        }
        var shownBySelection: [Int64: [TrainingExample.Item]] = [:]
        try db.query(
            "SELECT selection_id, position, doc_id, source, kind, title, text FROM impressions ORDER BY selection_id, position"
        ) { row in
            shownBySelection[row.int(0), default: []].append(
                TrainingExample.Item(
                    id: row.string(2), source: row.string(3), kind: row.string(4), title: row.string(5),
                    text: row.string(6), position: Int(row.int(1))))
        }
        return selections.compactMap { selection in
            TrainingExample.make(
                query: selection.query, shown: shownBySelection[selection.id] ?? [],
                chosenPosition: selection.chosen, ranker: selection.ranker,
                at: Date(timeIntervalSince1970: selection.at))
        }
    }

    // Each result's source and the start of its content, by result id (the
    // index row id).
    private func snapshots(ids: [String]) throws -> [String: (source: String, content: String)] {
        let rowIDs = ids.compactMap(Int64.init)
        guard !rowIDs.isEmpty else { return [:] }
        var snapshots: [String: (source: String, content: String)] = [:]
        try db.query(
            """
            SELECT d.id, d.source, substr(f.content, 1, ?)
            FROM documents d JOIN documents_fts f ON f.rowid = d.id
            WHERE d.id IN (\(rowIDs.map { _ in "?" }.joined(separator: ", ")))
            """,
            [.int(Int64(Self.snapshotCharacters))] + rowIDs.map { .int($0) }
        ) { row in
            snapshots[String(row.int(0))] = (row.string(1), row.string(2))
        }
        return snapshots
    }
}
