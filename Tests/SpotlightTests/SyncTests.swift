import Foundation
import Testing

@testable import Spotlight

// A pretend source for testing the scheduler: it writes one item, remembers
// which cursors it was given, and hands back the next cursor in its list.
struct FakeSource: Source {
    // An actor, so the (Sendable) source can record calls safely from any task.
    actor Calls {
        var cursors: [String?] = []
        func record(_ cursor: String?) { cursors.append(cursor) }
    }

    let id: String
    var displayName: String { "Fake \(id)" }
    var nextCursor: String? = nil
    var fails = false
    let calls = Calls()

    struct Failure: Error {}

    func sync(into index: SQLiteSearchEngine, since cursor: String?) async throws -> String? {
        await calls.record(cursor)
        if fails { throw Failure() }
        try await index.upsert([IndexedFile(path: "https://example.com/\(id)", name: "\(id) item", source: id)])
        return nextCursor
    }
}

@Suite struct SyncStateTests {
    @Test func neverSyncedSourceHasNoState() async throws {
        #expect(try await makeEngine().syncState(for: "gmail") == nil)
    }

    @Test func savesAndOverwritesState() async throws {
        let engine = try makeEngine()
        let first = SyncState(cursor: "100", syncedAt: Date(timeIntervalSince1970: 1))
        let second = SyncState(cursor: "200", syncedAt: Date(timeIntervalSince1970: 2))

        try await engine.saveSyncState(first, for: "gmail")
        #expect(try await engine.syncState(for: "gmail") == first)
        try await engine.saveSyncState(second, for: "gmail")
        #expect(try await engine.syncState(for: "gmail") == second)
    }

    @Test func missingCursorRoundTripsAsNil() async throws {
        let engine = try makeEngine()
        try await engine.saveSyncState(SyncState(cursor: nil, syncedAt: Date(timeIntervalSince1970: 5)), for: "files")

        #expect(try await engine.syncState(for: "files")?.cursor == nil)
    }

    @Test func removeAllOnlyTouchesOneSource() async throws {
        let engine = try makeEngine()
        try await engine.upsert([
            IndexedFile(path: "/a/local.txt", name: "local.txt"),
            IndexedFile(path: "https://mail.google.com/x", name: "mail thing", source: "gmail"),
        ])
        try await engine.saveSyncState(SyncState(cursor: "1", syncedAt: Date()), for: "gmail")

        try await engine.removeAll(from: "gmail")

        #expect(try await engine.titles(for: "mail").isEmpty)
        #expect(try await engine.titles(for: "local") == ["local.txt"])
        #expect(try await engine.syncState(for: "gmail") == nil)
    }
}

@Suite struct SyncSchedulerTests {
    @Test func passesTheSavedCursorToTheNextSync() async throws {
        let engine = try makeEngine()
        let source = FakeSource(id: "gmail", nextCursor: "c1")
        let scheduler = SyncScheduler(index: engine, sources: [source])

        await scheduler.syncAll()
        await scheduler.syncAll()

        // First sync starts from nothing; the second continues from "c1".
        #expect(await source.calls.cursors == [nil, "c1"])
        #expect(try await engine.syncState(for: "gmail")?.cursor == "c1")
    }

    @Test func aFailingSourceKeepsItsCursorAndOthersStillSync() async throws {
        let engine = try makeEngine()
        let old = SyncState(cursor: "old", syncedAt: Date(timeIntervalSince1970: 1))
        try await engine.saveSyncState(old, for: "broken")
        let scheduler = SyncScheduler(
            index: engine,
            sources: [FakeSource(id: "broken", nextCursor: "new", fails: true), FakeSource(id: "working")])

        let errors = await scheduler.syncAll()

        #expect(Array(errors.keys) == ["broken"])
        #expect(try await engine.syncState(for: "broken") == old)
        #expect(try await engine.syncState(for: "working") != nil)
        #expect(try await engine.titles(for: "working") == ["working item"])
    }

    @Test func itemsAreTaggedWithTheirSource() async throws {
        let engine = try makeEngine()
        await SyncScheduler(index: engine, sources: [FakeSource(id: "drive")]).syncAll()

        try await engine.removeAll(from: "drive")

        #expect(try await engine.titles(for: "drive").isEmpty)
    }
}

@Suite struct LocalFilesSourceTests {
    @Test func crawlsItsFoldersAndRecordsTheSync() async throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        try folder.write("hello", to: "notes.md")
        let engine = try makeEngine()
        let source = LocalFilesSource(folders: [IndexedFolder(url: folder.url, readsContent: true)])
        let before = Date()

        await SyncScheduler(index: engine, sources: [source]).syncAll()

        #expect(try await engine.titles(for: "notes") == ["notes.md"])
        let state = try #require(try await engine.syncState(for: LocalFilesSource.sourceID))
        #expect(state.cursor == nil)  // the disk has no change log, so no cursor
        #expect(state.syncedAt >= before.addingTimeInterval(-1))
    }

    @Test func settingsSubtitleMentionsTheLastSync() {
        #expect(SourcesPage.subtitle(lastSynced: nil) == "Apps, files and folders on this Mac")
        #expect(SourcesPage.subtitle(lastSynced: Date()).contains("· Synced"))
    }
}
