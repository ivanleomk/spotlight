import Foundation
import Testing

@testable import Spotlight

// MARK: - Helpers

// Answers by URL path: the first route whose key the path ends with wins
// (longest keys are tried first, so "/messages/a" beats "/messages").
// Anything unrouted gets a 404.
func router(_ routes: [String: String]) -> FakeHTTP {
    FakeHTTP { request in
        let path = request.url!.path
        for key in routes.keys.sorted(by: { $0.count > $1.count }) where path.hasSuffix(key) {
            return (200, routes[key]!)
        }
        return (404, "{}")
    }
}

// A signed-in account whose token never expires, talking to `http`.
func testAPI(_ http: FakeHTTP, email: String = "me@example.com") -> GoogleAPI {
    let credentials = GoogleCredentials(
        email: email, accessToken: "token", refreshToken: "r", expiresAt: .distantFuture, scopes: [])
    let tokens = GoogleTokens(oauth: GoogleOAuth(http: http), store: InMemoryStore(credentials))
    return GoogleAPI(email: email, tokens: tokens, http: http, backoff: { _ in })
}

extension FakeHTTP {
    func requestedPaths() async -> [String] { await log.requests.map { $0.url!.path } }
}

// A Gmail message as the API returns it (format=full), with a plain-text body.
func gmailMessage(id: String, subject: String, body: String, from: String = "Jane Doe <jane@x.com>",
                  labels: [String] = ["INBOX"], millis: Int = 1_700_000_000_000) -> String {
    let data = PKCE.base64URL(Data(body.utf8))
    return """
    {"id":"\(id)","labelIds":\(labels),"internalDate":"\(millis)","payload":{"mimeType":"multipart/alternative",
     "headers":[{"name":"Subject","value":"\(subject)"},{"name":"From","value":"\(from)"},{"name":"To","value":"me@example.com"}],
     "parts":[{"mimeType":"text/plain","filename":"","body":{"data":"\(data)"}},
              {"mimeType":"text/html","filename":"","body":{"data":"\(PKCE.base64URL(Data("<b>html</b>".utf8)))"}}]}}
    """
}

func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// MARK: - Text cleanup

@Suite struct GoogleTextTests {
    @Test func decodesURLSafeBase64WithoutPadding() {
        let encoded = PKCE.base64URL(Data("héllo?>".utf8))
        #expect(GoogleText.decodeBase64URL(encoded).map { String(decoding: $0, as: UTF8.self) } == "héllo?>")
    }

    @Test func stripsTagsStylesAndEntities() {
        let html = "<style>p{color:red}</style><p>Fish &amp; chips</p><br>at&nbsp;noon"
        #expect(GoogleText.tidy(GoogleText.stripHTML(html)) == "Fish & chips\nat noon")
    }

    @Test func removesQuotedReplies() {
        let email = "Sounds good!\n\nOn Tue, 30 Sep 2026, Jane <jane@x.com> wrote:\n> old stuff\n> more"
        #expect(GoogleText.tidy(GoogleText.removeQuotedReply(email)) == "Sounds good!")
        #expect(GoogleText.removeQuotedReply("keep\n> quoted\nalso keep") == "keep\nalso keep")
    }

    @Test func tidyCollapsesWhitespaceAndCaps() {
        #expect(GoogleText.tidy("a   b\n\n\n c") == "a b\n c")
        #expect(GoogleText.tidy(String(repeating: "x", count: 10), limit: 4) == "xxxx")
    }

    @Test func senderDisplayNames() {
        #expect(GoogleText.displayName(fromAddress: "Jane Doe <jane@x.com>") == "Jane Doe")
        #expect(GoogleText.displayName(fromAddress: "\"Doe, Jane\" <jane@x.com>") == "Doe, Jane")
        #expect(GoogleText.displayName(fromAddress: "<jane@x.com>") == "jane@x.com")
        #expect(GoogleText.displayName(fromAddress: "jane@x.com") == "jane@x.com")
    }

    @Test func parsesBothGoogleTimestampStyles() {
        #expect(GoogleText.date(fromISO8601: "2026-09-30T06:00:00.123Z") != nil)
        #expect(GoogleText.date(fromISO8601: "2026-09-30T14:00:00+08:00")
            == GoogleText.date(fromISO8601: "2026-09-30T06:00:00Z"))
        #expect(GoogleText.date(fromISO8601: "garbage") == nil)
    }
}

// MARK: - API client

@Suite struct GoogleAPITests {
    // Replies with each status in turn (the last one repeats).
    final class Sequence: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [Int]
        init(_ statuses: [Int]) { self.statuses = statuses }
        func next() -> Int { lock.withLock { statuses.count > 1 ? statuses.removeFirst() : statuses[0] } }
    }

    @Test func retriesWhenRateLimitedThenSucceeds() async throws {
        let replies = Sequence([429, 503, 200])
        let http = FakeHTTP { _ in
            let status = replies.next()
            return (status, status == 200 ? #"{"historyId":"7"}"# : "busy")
        }
        actor Waits { var attempts: [Int] = []; func add(_ n: Int) { attempts.append(n) } }
        let waits = Waits()
        var api = testAPI(http)
        api.backoff = { await waits.add($0) }

        let profile: GmailSource.Profile = try await api.get("https://gmail.googleapis.com/gmail/v1/users/me/profile")

        #expect(profile.historyId == "7")
        #expect(await http.log.requests.count == 3)
        #expect(await waits.attempts == [1, 2])  // waited before each retry
        #expect(await http.log.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func quotaErrorsAre403sAndAreRetried() async throws {
        let replies = Sequence([403, 200])
        let http = FakeHTTP { _ in
            replies.next() == 403
                ? (403, #"{"error":{"code":403,"message":"Quota exceeded for quota metric 'Total Query Cost'"}}"#)
                : (200, "{}")
        }

        _ = try await testAPI(http).data("https://x.test/a")

        #expect(await http.log.requests.count == 2)
    }

    @Test func otherForbiddenErrorsAreNotRetried() async {
        let http = FakeHTTP { _ in (403, #"{"error":{"message":"Insufficient Permission"}}"#) }

        await #expect(throws: GoogleAPIError.self) { try await testAPI(http).data("https://x.test/a") }
        #expect(await http.log.requests.count == 1)
    }

    @Test func givesUpAfterTooManyRateLimits() async {
        let http = FakeHTTP { _ in (429, "slow down") }

        await #expect(throws: GoogleAPIError.self) { try await testAPI(http).data("https://x.test/a") }
        #expect(await http.log.requests.count == GoogleAPI.maxAttempts)
    }

    @Test func notFoundIsItsOwnError() async {
        await #expect(throws: GoogleAPIError.notFound) { try await testAPI(router([:])).data("https://x.test/a") }
    }

    @Test func concurrentMapKeepsOrderAndDropsNils() async throws {
        let result = try await Array(1...20).concurrentMap(width: 3) { $0 % 5 == 0 ? nil : $0 * 10 }

        #expect(result == Array(1...20).filter { $0 % 5 != 0 }.map { $0 * 10 })
    }
}

// MARK: - Gmail

@Suite struct GmailSourceTests {
    @Test func messageBecomesAnIndexRow() throws {
        let message: GmailSource.Message = try decode(
            gmailMessage(id: "abc", subject: "Lunch?", body: "Thai at noon\n\nOn Mon, Jane wrote:\n> earlier"))

        let row = try #require(GmailSource.indexedFile(from: message, account: "me@example.com"))

        #expect(row.name == "Lunch?")
        #expect(row.kind == .email)
        #expect(row.detail == "Jane Doe")
        #expect(row.modifiedAt == 1_700_000_000)
        #expect(row.content.contains("Thai at noon"))
        #expect(!row.content.contains("earlier"))  // quoted reply removed
        #expect(row.content.contains("From: Jane Doe <jane@x.com>"))
        #expect(row.path == "https://mail.google.com/mail/?authuser=me@example.com#all/abc")
        #expect(row.source == "gmail:me@example.com")
    }

    @Test func htmlOnlyMessagesUseTheStrippedHTML() throws {
        let html = PKCE.base64URL(Data("<p>Hello <b>there</b></p>".utf8))
        let message: GmailSource.Message = try decode("""
            {"id":"h","payload":{"mimeType":"text/html","body":{"data":"\(html)"},"headers":[]}}
            """)

        let row = try #require(GmailSource.indexedFile(from: message, account: "me@example.com"))

        #expect(row.content.contains("Hello there"))
        #expect(row.name == "(no subject)")
    }

    @Test func promotionsSpamAndDraftsAreSkipped() throws {
        for label in ["CATEGORY_PROMOTIONS", "SPAM", "DRAFT"] {
            let message: GmailSource.Message = try decode(gmailMessage(id: "x", subject: "s", body: "b", labels: [label]))
            #expect(GmailSource.indexedFile(from: message, account: "me@example.com") == nil)
        }
    }

    @Test func firstSyncThenHistorySync() async throws {
        let engine = try makeEngine()
        let http = router([
            "/profile": #"{"historyId":"100"}"#,
            "/messages": #"{"messages":[{"id":"a"},{"id":"b"}]}"#,
            "/messages/a": gmailMessage(id: "a", subject: "Alpha invoice", body: "one"),
            "/messages/b": gmailMessage(id: "b", subject: "Bravo trip", body: "two"),
            "/history": #"{"historyId":"120","history":[{"messagesAdded":[{"message":{"id":"c","labelIds":["INBOX"]}}]},{"messagesDeleted":[{"message":{"id":"a"}}]}]}"#,
            "/messages/c": gmailMessage(id: "c", subject: "Charlie party", body: "three"),
        ])
        let source = GmailSource(api: testAPI(http))

        let first = try await source.sync(into: engine, since: nil)
        #expect(first == "100")
        #expect(try await engine.titles(for: "invoice") == ["Alpha invoice"])

        let second = try await source.sync(into: engine, since: first)
        #expect(second == "120")
        #expect(try await engine.titles(for: "invoice").isEmpty)  // deleted in Gmail
        #expect(try await engine.titles(for: "party") == ["Charlie party"])
        #expect(try await engine.titles(for: "bravo") == ["Bravo trip"])
    }

    @Test func expiredHistoryFallsBackToAFullSync() async throws {
        let engine = try makeEngine()
        let http = router([  // no "/history" route, so it 404s like an expired bookmark
            "/profile": #"{"historyId":"200"}"#,
            "/messages": #"{"messages":[{"id":"a"}]}"#,
            "/messages/a": gmailMessage(id: "a", subject: "Alpha", body: "one"),
        ])

        let cursor = try await GmailSource(api: testAPI(http)).sync(into: engine, since: "5")

        #expect(cursor == "200")
        #expect(try await engine.titles(for: "alpha") == ["Alpha"])
    }

    @Test func aResumedFirstSyncSkipsWhatItAlreadyHas() async throws {
        let engine = try makeEngine()
        try await engine.upsert([IndexedFile(
            path: GmailSource.link(messageID: "a", account: "me@example.com"), name: "Alpha",
            kind: .email, source: "gmail:me@example.com")])
        let http = router([
            "/profile": #"{"historyId":"1"}"#,
            "/messages": #"{"messages":[{"id":"a"},{"id":"b"}]}"#,
            "/messages/b": gmailMessage(id: "b", subject: "Bravo", body: "two"),
        ])

        _ = try await GmailSource(api: testAPI(http)).sync(into: engine, since: nil)

        #expect(!(await http.requestedPaths()).contains { $0.hasSuffix("/messages/a") })
        #expect(try await engine.titles(for: "alpha") == ["Alpha"])
    }
}

// MARK: - Calendar

@Suite struct CalendarSourceTests {
    private let listJSON = """
        {"items":[{"id":"primary","summary":"Ivan","selected":true,"accessRole":"owner"},
                  {"id":"hidden@group","summary":"Holidays","selected":false,"accessRole":"reader"}]}
        """

    private func eventsJSON(_ events: String...) -> String { #"{"items":[\#(events.joined(separator: ","))]}"# }

    private func event(_ id: String, _ title: String, start: String = #"{"dateTime":"2026-09-30T14:00:00+08:00"}"#,
                       status: String = "confirmed") -> String {
        """
        {"id":"\(id)","status":"\(status)","summary":"\(title)","location":"Room 4","description":"<p>Agenda: budget</p>",
         "htmlLink":"https://www.google.com/calendar/event?eid=\(id)","start":\(start),
         "attendees":[{"email":"sam@x.com","displayName":"Sam"}]}
        """
    }

    @Test func eventBecomesAnIndexRow() throws {
        let decoded: CalendarSource.Event = try decode(event("e1", "Planning"))

        let row = try #require(CalendarSource.indexedFile(from: decoded, calendarName: "Ivan", account: "me@example.com"))

        #expect(row.name == "Planning")
        #expect(row.kind == .event)
        #expect(row.detail == "Room 4")
        #expect(row.modifiedAt == GoogleText.date(fromISO8601: "2026-09-30T06:00:00Z")!.timeIntervalSince1970)
        #expect(row.content.contains("Agenda: budget"))
        #expect(row.content.contains("Sam sam@x.com"))
    }

    @Test func allDayAndCancelledEvents() throws {
        let allDay: CalendarSource.Event = try decode(event("e2", "Holiday", start: #"{"date":"2026-10-01"}"#))
        let cancelled: CalendarSource.Event = try decode(event("e3", "Nope", status: "cancelled"))

        #expect(CalendarSource.indexedFile(from: allDay, calendarName: "", account: "me@example.com") != nil)
        #expect(CalendarSource.indexedFile(from: cancelled, calendarName: "", account: "me@example.com") == nil)
    }

    @Test func syncsVisibleCalendarsAndPrunesVanishedEvents() async throws {
        let engine = try makeEngine()
        let first = router([
            "/users/me/calendarList": listJSON,
            "/calendars/primary/events": eventsJSON(event("e1", "Planning"), event("e2", "Standup")),
            "/calendars/hidden@group/events": eventsJSON(event("h1", "Secret holiday")),
        ])
        let start = Date()
        _ = try await CalendarSource(api: testAPI(first), now: { start }).sync(into: engine, since: nil)

        #expect(try await engine.titles(for: "planning") == ["Planning"])
        #expect(try await engine.titles(for: "holiday").isEmpty)  // calendar hidden in Google Calendar

        // Next sync: Standup was deleted in Google Calendar.
        let second = router([
            "/users/me/calendarList": listJSON,
            "/calendars/primary/events": eventsJSON(event("e1", "Planning")),
        ])
        _ = try await CalendarSource(api: testAPI(second), now: { start.addingTimeInterval(60) })
            .sync(into: engine, since: nil)

        #expect(try await engine.titles(for: "standup").isEmpty)
        #expect(try await engine.titles(for: "planning") == ["Planning"])
    }
}

// MARK: - Drive

@Suite struct DriveSourceTests {
    private func file(_ id: String, _ name: String, mime: String = "application/pdf", mine: Bool = true,
                      modified: String = "2026-09-01T00:00:00.000Z", viewed: String? = nil, trashed: Bool = false) -> String {
        """
        {"id":"\(id)","name":"\(name)","mimeType":"\(mime)","modifiedTime":"\(modified)"\(viewed.map { #","viewedByMeTime":"\#($0)""# } ?? ""),
         "trashed":\(trashed),"owners":[{"displayName":"Sam Lee","me":\(mine)}]}
        """
    }

    @Test func fileBecomesAnIndexRowDatedByLatestTouch() throws {
        let decoded: DriveSource.File = try decode(file(
            "f1", "Budget.pdf", mine: false, modified: "2026-09-01T00:00:00.000Z", viewed: "2026-09-20T00:00:00.000Z"))

        let row = DriveSource.indexedFile(from: decoded, text: "", account: "me@example.com")

        #expect(row.path == "https://drive.google.com/open?id=f1")
        #expect(row.detail == "Sam Lee")
        #expect(row.modifiedAt == GoogleText.date(fromISO8601: "2026-09-20T00:00:00Z")!.timeIntervalSince1970)
    }

    @Test func firstSyncExportsDocsThenChangesUpdateAndRemove() async throws {
        let engine = try makeEngine()
        let first = router([
            "/changes/startPageToken": #"{"startPageToken":"t1"}"#,
            "/files": #"{"files":[\#(file("d1", "Roadmap", mime: DriveSource.googleDoc)),\#(file("p1", "Receipt.pdf"))]}"#,
            "/files/d1/export": "Quarterly zeppelin goals",
        ])

        let cursor = try await DriveSource(api: testAPI(first)).sync(into: engine, since: nil)

        #expect(cursor == "t1")
        #expect(try await engine.titles(for: "zeppelin") == ["Roadmap"])  // found by the Doc's text
        #expect(try await engine.titles(for: "receipt") == ["Receipt.pdf"])

        let changes = router([
            "/changes": """
                {"newStartPageToken":"t2","changes":[
                  {"fileId":"p1","removed":true},
                  {"fileId":"n1","file":\(file("n1", "Notes.pdf"))},
                  {"fileId":"d1","file":\(file("d1", "Roadmap", mime: DriveSource.googleDoc, trashed: true))}]}
                """
        ])
        let next = try await DriveSource(api: testAPI(changes)).sync(into: engine, since: cursor)

        #expect(next == "t2")
        #expect(try await engine.titles(for: "receipt").isEmpty)  // deleted
        #expect(try await engine.titles(for: "roadmap").isEmpty)  // trashed
        #expect(try await engine.titles(for: "notes") == ["Notes.pdf"])
    }
}

// MARK: - Scheduler sources

@Suite struct GoogleSourceListTests {
    @Test func onlyTickedServicesOfSignedInAccountsSync() async {
        let tokens = GoogleTokens(
            oauth: GoogleOAuth(http: router([:])),
            store: InMemoryStore(
                GoogleCredentials(email: "a@x.com", accessToken: "", refreshToken: "", expiresAt: .distantFuture, scopes: []),
                GoogleCredentials(email: "b@x.com", accessToken: "", refreshToken: "", expiresAt: .distantFuture, scopes: [])))
        let name = "SpotlightTests-\(UUID().uuidString)"
        let preferences = GoogleServicePreferences(defaults: UserDefaults(suiteName: name)!)
        preferences.setEnabled([.gmail], for: "b@x.com")

        let ids = await GoogleAccounts.sources(tokens: tokens, preferences: preferences).map(\.id)

        #expect(ids == ["gmail:a@x.com", "drive:a@x.com", "calendar:a@x.com", "gmail:b@x.com"])
    }
}
