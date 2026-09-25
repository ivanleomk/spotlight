import Foundation

// The Google products we can index for an account. Each (service, account)
// pair is its own Source, e.g. "gmail:me@example.com", with its own sync
// bookmark, so they sync separately but are searched and ranked together.
enum GoogleService: String, CaseIterable, Identifiable, Sendable {
    case gmail, drive, calendar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gmail: "Email"
        case .drive: "Drive"
        case .calendar: "Calendar"
        }
    }

    // What gets indexed, shown under the name in Settings.
    var detail: String {
        switch self {
        case .gmail: "Subjects, senders and message text"
        case .drive: "File names and Google Docs text"
        case .calendar: "Event titles, times and guests"
        }
    }

    var symbolName: String {
        switch self {
        case .gmail: "envelope"
        case .drive: "externaldrive"
        case .calendar: "calendar"
        }
    }

    // The read-only permission it needs from Google.
    var scope: String {
        switch self {
        case .gmail: "https://www.googleapis.com/auth/gmail.readonly"
        case .drive: "https://www.googleapis.com/auth/drive.readonly"
        case .calendar: "https://www.googleapis.com/auth/calendar.readonly"
        }
    }

    func sourceID(for email: String) -> String { "\(rawValue):\(email)" }

    // The Source that syncs this service for one account.
    func source(for email: String, tokens: GoogleTokens) -> any Source {
        let api = GoogleAPI(email: email, tokens: tokens)
        switch self {
        case .gmail: return GmailSource(api: api)
        case .drive: return DriveSource(api: api)
        case .calendar: return CalendarSource(api: api)
        }
    }
}

// Which services are switched on for each account, remembered between launches.
// UserDefaults is macOS's small key-value store for app preferences.
struct GoogleServicePreferences: @unchecked Sendable {
    // @unchecked: UserDefaults is thread-safe, but isn't marked Sendable.
    var defaults: UserDefaults = .standard

    private func key(_ email: String) -> String { "google.services.\(email)" }

    // New accounts start with everything on.
    func enabled(for email: String) -> Set<GoogleService> {
        guard let saved = defaults.stringArray(forKey: key(email)) else { return Set(GoogleService.allCases) }
        return Set(saved.compactMap(GoogleService.init(rawValue:)))
    }

    func setEnabled(_ services: Set<GoogleService>, for email: String) {
        defaults.set(services.map(\.rawValue).sorted(), forKey: key(email))
    }

    func forget(_ email: String) {
        defaults.removeObject(forKey: key(email))
    }
}
