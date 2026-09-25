import Foundation

// Runs each source's sync and remembers where it got up to.
actor SyncScheduler {
    private let index: SQLiteSearchEngine
    private let sources: [any Source]

    init(index: SQLiteSearchEngine, sources: [any Source]) {
        self.index = index
        self.sources = sources
    }

    // Syncs every source, one after another. One failing source (say, Gmail while
    // offline) doesn't stop the others. Returns each source's error, if it had one.
    @discardableResult
    func syncAll() async -> [String: any Error] {
        var errors: [String: any Error] = [:]
        for source in sources {
            if Task.isCancelled { break }
            do {
                try await sync(source)
            } catch {
                NSLog("Sync of \(source.displayName) failed: \(error)")
                errors[source.id] = error
            }
        }
        return errors
    }

    private func sync(_ source: any Source) async throws {
        let started = Date()
        let previous = try await index.syncState(for: source.id)
        let cursor = try await source.sync(into: index, since: previous?.cursor)
        // Only saved after a successful sync: if it throws, the old cursor stays, and
        // the next attempt picks up from the same place instead of skipping ahead.
        try await index.saveSyncState(SyncState(cursor: cursor, syncedAt: started), for: source.id)
    }
}
