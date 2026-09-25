import Foundation
import Observation

// The Google accounts as the Settings page sees them: who's signed in, plus
// Add Account and Disconnect. @Observable makes SwiftUI redraw when these change.
@MainActor
@Observable
final class GoogleAccounts {
    private(set) var emails: [String] = []
    private(set) var pictureURLs: [String: URL] = [:]
    // Per source id ("gmail:me@x.com"): how many items it has indexed, and
    // when it last finished syncing.
    private(set) var itemCounts: [String: Int] = [:]
    private(set) var lastSynced: [String: Date] = [:]

    // Called after anything that should trigger a sync (an account added, a
    // service ticked). Set by the app delegate.
    @ObservationIgnored var onChange: @MainActor () -> Void = {}
    // Which services are ticked for each account.
    private(set) var enabled: [String: Set<GoogleService>] = [:]
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    // Every source an account can feed, e.g. "gmail:me@example.com".
    // nonisolated: pure calculation, so callable from any thread, not just the main one.
    nonisolated static func sourceIDs(for email: String) -> [String] {
        GoogleService.allCases.map { $0.sourceID(for: email) }
    }

    @ObservationIgnored let tokens: GoogleTokens
    @ObservationIgnored private let oauth: GoogleOAuth
    @ObservationIgnored private let index: SQLiteSearchEngine
    @ObservationIgnored private let preferences: GoogleServicePreferences
    @ObservationIgnored private let signIn = WebSignIn()

    init(
        tokens: GoogleTokens, oauth: GoogleOAuth = GoogleOAuth(), index: SQLiteSearchEngine,
        preferences: GoogleServicePreferences = GoogleServicePreferences()
    ) {
        self.tokens = tokens
        self.oauth = oauth
        self.index = index
        self.preferences = preferences
    }

    func refresh() async {
        emails = await tokens.emails()
        pictureURLs = await tokens.pictureURLs()
        enabled = Dictionary(uniqueKeysWithValues: emails.map { ($0, preferences.enabled(for: $0)) })
        for email in emails {
            for id in Self.sourceIDs(for: email) {
                itemCounts[id] = try? await index.count(from: id)
                lastSynced[id] = try? await index.syncState(for: id)?.syncedAt
            }
        }
    }

    // The sources to sync right now: each ticked service of each account.
    // `nonisolated` + only thread-safe inputs, so the background scheduler can call it.
    nonisolated static func sources(
        tokens: GoogleTokens, preferences: GoogleServicePreferences = GoogleServicePreferences()
    ) async -> [any Source] {
        var sources: [any Source] = []
        for email in await tokens.emails() {
            let on = preferences.enabled(for: email)
            for service in GoogleService.allCases where on.contains(service) {
                sources.append(service.source(for: email, tokens: tokens))
            }
        }
        return sources
    }

    func isEnabled(_ service: GoogleService, for email: String) -> Bool {
        enabled[email]?.contains(service) ?? false
    }

    // Ticking or unticking a service. Unticking also removes what it had
    // indexed, so its results disappear from search straight away.
    func setEnabled(_ isOn: Bool, _ service: GoogleService, for email: String) async {
        var services = enabled[email] ?? []
        if isOn { services.insert(service) } else { services.remove(service) }
        enabled[email] = services
        preferences.setEnabled(services, for: email)
        if isOn {
            onChange()
        } else {
            try? await index.removeAll(from: service.sourceID(for: email))
            itemCounts[service.sourceID(for: email)] = 0
        }
    }

    // Signs in one more account (or the same one again, which just replaces it).
    func add() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let pkce = PKCE()
            let state = PKCE.randomString()
            let callback = try await signIn.start(
                url: oauth.authorizationURL(pkce: pkce, state: state),
                callbackScheme: oauth.config.callbackScheme)
            let code = try GoogleOAuth.code(from: callback, expectedState: state)
            let credentials = try await oauth.exchange(code: code, pkce: pkce)
            try await tokens.save(credentials)
            await refresh()
            onChange()
        } catch GoogleAuthError.cancelled {
            // Closing the sheet isn't an error worth showing.
        } catch {
            errorMessage = "\(error)"
        }
    }

    func disconnect(_ email: String) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await tokens.signOut(email)
        } catch {
            errorMessage = "\(error)"
            return
        }
        for source in Self.sourceIDs(for: email) {
            try? await index.removeAll(from: source)
        }
        preferences.forget(email)
        await refresh()
    }
}
