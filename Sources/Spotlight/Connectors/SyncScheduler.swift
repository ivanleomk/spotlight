import Foundation

// Runs each source's sync and remembers where it got up to, now and then
// every few minutes in the background.
actor SyncScheduler {
    private let index: SQLiteSearchEngine
    // Asked afresh before every run, so connecting an account or ticking a
    // service is picked up without restarting.
    private let sources: @Sendable () async -> [any Source]
    private var isSyncing = false
    private var wantsAnotherRun = false
    private var timer: Task<Void, Never>?

    init(index: SQLiteSearchEngine, sources: @escaping @Sendable () async -> [any Source]) {
        self.index = index
        self.sources = sources
    }

    // A fixed list (used by tests).
    init(index: SQLiteSearchEngine, sources: [any Source]) {
        self.init(index: index, sources: { sources })
    }

    // Syncs now, then again every `interval`.
    func start(every interval: Duration) {
        timer?.cancel()
        timer = Task {
            while !Task.isCancelled {
                await syncAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    // Syncs every source at the same time: they're independent, so a slow one
    // (Gmail's first sync can take hours) mustn't hold up the rest. One failing
    // source (say, Gmail while offline) doesn't stop the others. Returns each
    // source's error, if it had one.
    //
    // If a run is already going, this doesn't start a second one alongside it
    // (they'd fetch the same things twice); it asks for one more run afterwards.
    @discardableResult
    func syncAll() async -> [String: any Error] {
        if isSyncing {
            wantsAnotherRun = true
            return [:]
        }
        isSyncing = true
        defer { isSyncing = false }

        var errors: [String: any Error] = [:]
        repeat {
            wantsAnotherRun = false
            // A task group runs one child task per source and waits for them all.
            let failures = await withTaskGroup(of: (String, (any Error)?).self) { group in
                for source in await sources() {
                    group.addTask {
                        do {
                            try await self.sync(source)
                            return (source.id, nil)
                        } catch {
                            NSLog("Sync of \(source.displayName) failed: \(error)")
                            return (source.id, error)
                        }
                    }
                }
                var failures: [String: any Error] = [:]
                for await (id, error) in group {
                    if let error { failures[id] = error }
                }
                return failures
            }
            errors.merge(failures) { $1 }
        } while wantsAnotherRun && !Task.isCancelled
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
