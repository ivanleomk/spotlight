import Foundation
import Testing

@testable import Spotlight

@Suite struct RankingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day = Ranking.day

    @Test func localThingsGetNoBoost() {
        for kind in [DocumentKind.file, .folder, .app] {
            #expect(Ranking.boost(for: kind, date: now, now: now) == 1)
        }
    }

    @Test func emailBoostHalvesEveryThirtyDays() {
        #expect(Ranking.boost(for: .email, date: now, now: now) == 2.5)
        #expect(Ranking.boost(for: .email, date: now - 30 * day, now: now) == 1.75)
        #expect(Ranking.boost(for: .email, date: now - 60 * day, now: now) == 1.375)
        #expect(Ranking.boost(for: .email, date: nil, now: now) == 1)
    }

    @Test func eventsCountDistanceFromNowBothWays() {
        let tomorrow = Ranking.boost(for: .event, date: now + day, now: now)
        let yesterday = Ranking.boost(for: .event, date: now - day, now: now)
        let nextMonth = Ranking.boost(for: .event, date: now + 30 * day, now: now)

        #expect(tomorrow == yesterday)
        #expect(tomorrow > nextMonth)
    }

    @Test func aRecentWeakerMatchBeatsAnOldStrongerOne() {
        let old = SearchResult(id: "old", title: "old", kind: .email, score: 10, date: now - 365 * day)
        let recent = SearchResult(id: "new", title: "new", kind: .email, score: 7, date: now - day)

        #expect(Ranking.rerank([old, recent], now: now).map(\.id) == ["new", "old"])
    }

    @Test func aMuchStrongerMatchStillWins() {
        let old = SearchResult(id: "old", title: "old", kind: .email, score: 30, date: now - 365 * day)
        let recent = SearchResult(id: "new", title: "new", kind: .email, score: 7, date: now)

        #expect(Ranking.rerank([old, recent], now: now).map(\.id) == ["old", "new"])
    }

    @Test func searchAppliesRecency() async throws {
        let engine = try makeEngine()
        await engine.setClock { [now] in now }
        try await engine.upsert([
            IndexedFile(path: "https://m/old", name: "invoice", kind: .email, modifiedAt: (now - 400 * day).timeIntervalSince1970),
            IndexedFile(path: "https://m/new", name: "invoice", kind: .email, modifiedAt: (now - 2 * day).timeIntervalSince1970),
        ])

        let results = try await engine.search(SearchQuery(text: "invoice", kinds: [.email]))

        #expect(results.map(\.subtitle) == ["https://m/new", "https://m/old"])
        #expect(results.first?.date == now - 2 * day)
    }
}

@Suite struct ResultSectionTests {
    private func section(_ title: String, _ count: Int) -> ResultSection {
        ResultSection(title: title, items: (0..<count).map { SearchResult(id: "\(title)\($0)", title: "x") })
    }

    @Test func dropsEmptySectionsAndTrimsTheLongest() {
        let fitted = ResultSection.fitting(
            [section("Apps", 3), section("Mail", 0), section("Calendar", 3), section("Files", 4)], maxRows: 8)

        #expect(fitted.map(\.title) == ["Apps", "Calendar", "Files"])
        // Files (the longest) loses a row first; then it's a three-way tie, and
        // the last tied section gives one up.
        #expect(fitted.map(\.items.count) == [3, 3, 2])
    }

    @Test func everySectionKeepsItsBestResult() {
        let fitted = ResultSection.fitting((0..<6).map { section("S\($0)", 3) }, maxRows: 4)

        #expect(fitted.allSatisfy { $0.items.count >= 1 })
    }
}

@Suite struct ResultTextTests {
    private let now = GoogleText.date(fromISO8601: "2026-09-25T12:00:00Z")!

    @Test func emailShowsSenderAndWhen() {
        let email = SearchResult(id: "1", title: "Hi", kind: .email, detail: "Jane Doe", date: now - 3 * Ranking.day)

        #expect(ResultText.secondary(for: email, now: now) == "Jane Doe · 3 days ago")
    }

    @Test func eventShowsStartAndLocation() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = GoogleText.date(fromISO8601: "2026-09-30T14:00:00Z")!

        #expect(ResultText.eventTime(start, now: now, calendar: utc) == "Wed 30 Sep, 14:00")
        let event = SearchResult(id: "2", title: "Planning", kind: .event, detail: "Room 4", date: start)
        #expect(ResultText.secondary(for: event, now: now)?.hasSuffix("· Room 4") == true)
    }

    @Test func eventsInOtherYearsShowTheYear() {
        let nextYear = GoogleText.date(fromISO8601: "2027-01-05T09:00:00Z")!

        #expect(ResultText.eventTime(nextYear, now: now).contains("2027"))
    }

    @Test func filesShowTheirFolderAndAppsNothing() {
        let file = SearchResult(id: "3", title: "a.md", subtitle: "/tmp/notes/a.md", kind: .file)
        let app = SearchResult(id: "4", title: "Safari", subtitle: "/Applications/Safari.app", kind: .app)

        #expect(ResultText.secondary(for: file, now: now) == "/tmp/notes")
        #expect(ResultText.secondary(for: app, now: now) == nil)
    }

    @Test func webResultsOpenInTheBrowserAndFilesInFinder() {
        let web = SearchResult(id: "5", title: "x", subtitle: "https://drive.google.com/open?id=f1", kind: .driveFile)
        let file = SearchResult(id: "6", title: "y", subtitle: "/tmp/y.txt", kind: .file)

        #expect(web.openURL == URL(string: "https://drive.google.com/open?id=f1"))
        #expect(file.openURL?.isFileURL == true)
    }

    @Test func serviceStatusLine() {
        #expect(ServiceRow.status(isOn: false, count: 10, lastSynced: nil) == "Off")
        #expect(ServiceRow.status(isOn: true, count: nil, lastSynced: nil) == "Syncing…")
        #expect(ServiceRow.status(isOn: true, count: 40, lastSynced: nil) == "40 so far…")
        #expect(ServiceRow.status(isOn: true, count: 1234, lastSynced: Date()).hasPrefix("1,234 items · "))
    }
}

@Suite struct SourceIndexingTests {
    @Test func webLinksAreNotSearchable() async throws {
        let engine = try makeEngine()
        try await engine.upsert([IndexedFile(
            path: "https://mail.google.com/mail/?authuser=me@example.com#all/1", name: "Lunch", kind: .email)])

        #expect(try await engine.titles(for: "google").isEmpty)
        #expect(try await engine.titles(for: "lunch") == ["Lunch"])
    }

    @Test func removeAndPruneBySource() async throws {
        let engine = try makeEngine()
        try await engine.upsert([
            IndexedFile(path: "https://c/1", name: "Standup", kind: .event, source: "calendar:a"),
            IndexedFile(path: "https://c/2", name: "Retro", kind: .event, source: "calendar:a"),
            IndexedFile(path: "https://m/1", name: "Receipt", kind: .email, source: "gmail:a"),
        ], indexedAt: 1)
        try await engine.upsert([IndexedFile(path: "https://c/2", name: "Retro", kind: .event, source: "calendar:a")], indexedAt: 5)

        try await engine.prune(source: "calendar:a", olderThan: 5)
        #expect(try await engine.paths(from: "calendar:a") == ["https://c/2"])
        #expect(try await engine.count(from: "gmail:a") == 1)

        try await engine.remove(paths: ["https://m/1"])
        #expect(try await engine.count(from: "gmail:a") == 0)
        #expect(try await engine.titles(for: "receipt").isEmpty)
    }
}
