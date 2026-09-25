import Foundation

// One account's calendar events, from a year ago to six months ahead.
//
// Calendars are small (hundreds to a few thousand events), so every sync
// simply re-reads that window from every calendar you have ticked in Google
// Calendar, and anything we didn't see again (deleted, or now outside the
// window) is pruned. No bookmark needed.
struct CalendarSource: Source {
    let api: GoogleAPI
    var pastDays = 365
    var futureDays = 180
    var now: @Sendable () -> Date = Date.init

    var id: String { GoogleService.calendar.sourceID(for: api.email) }
    var displayName: String { "Calendar (\(api.email))" }

    static let base = "https://www.googleapis.com/calendar/v3"

    func sync(into index: SQLiteSearchEngine, since cursor: String?) async throws -> String? {
        let started = now()
        let calendars: CalendarList = try await api.get("\(Self.base)/users/me/calendarList")
        // Only calendars shown in Google Calendar (not ones you've hidden), and
        // only ones we can read event details from.
        let visible = (calendars.items ?? []).filter { $0.selected == true && $0.accessRole != "freeBusyReader" }

        let window = [
            URLQueryItem(name: "singleEvents", value: "true"),  // one row per repeat of a recurring event
            URLQueryItem(name: "timeMin", value: Self.iso(started.addingTimeInterval(-Double(pastDays) * Ranking.day))),
            URLQueryItem(name: "timeMax", value: Self.iso(started.addingTimeInterval(Double(futureDays) * Ranking.day))),
            URLQueryItem(name: "maxResults", value: "2500"),
        ]
        for calendar in visible {
            let calendarID = calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar.id
            var pageToken: String?
            repeat {
                var query = window
                if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                let page: EventList = try await api.get("\(Self.base)/calendars/\(calendarID)/events", query)
                let files = (page.items ?? []).compactMap {
                    Self.indexedFile(from: $0, calendarName: calendar.summary ?? "", account: api.email)
                }
                try await index.upsert(files, indexedAt: started.timeIntervalSince1970)
                pageToken = page.nextPageToken
            } while pageToken != nil
        }
        try await index.prune(source: id, olderThan: started.timeIntervalSince1970)
        return nil
    }

    static func indexedFile(from event: Event, calendarName: String, account: String) -> IndexedFile? {
        guard event.status != "cancelled", let link = event.htmlLink, let start = event.start?.parsed else { return nil }
        let guests = (event.attendees ?? []).map { [$0.displayName, $0.email].compactMap { $0 }.joined(separator: " ") }
        let content = [
            event.location ?? "",
            GoogleText.tidy(GoogleText.stripHTML(event.description ?? "")),
            guests.isEmpty ? "" : "Guests: " + guests.joined(separator: ", "),
            event.organizer?.displayName ?? event.organizer?.email ?? "",
            calendarName,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        return IndexedFile(
            path: link,
            name: (event.summary ?? "").isEmpty ? "(No title)" : event.summary!,
            kind: .event,
            modifiedAt: start.timeIntervalSince1970,  // for events, "when" is when it starts
            content: content,
            detail: event.location ?? "",
            source: GoogleService.calendar.sourceID(for: account))
    }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    // MARK: - Calendar's JSON (only the fields we use)

    struct CalendarList: Decodable {
        struct Entry: Decodable {
            let id: String
            let summary: String?
            let selected: Bool?
            let accessRole: String?
        }
        let items: [Entry]?
    }
    struct EventList: Decodable {
        let items: [Event]?
        let nextPageToken: String?
    }
    struct Event: Decodable {
        struct Person: Decodable { let email: String?; let displayName: String? }
        // Timed events have `dateTime`; all-day events only a `date` ("2026-09-30").
        struct Moment: Decodable {
            let dateTime: String?
            let date: String?

            var parsed: Date? {
                if let dateTime { return GoogleText.date(fromISO8601: dateTime) }
                if let date { return CalendarSource.allDay.date(from: date) }
                return nil
            }
        }
        let status: String?
        let summary: String?
        let description: String?
        let location: String?
        let htmlLink: String?
        let start: Moment?
        let attendees: [Person]?
        let organizer: Person?
    }

    // All-day dates are in your time zone ("2026-09-30" means your Tuesday).
    static let allDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
