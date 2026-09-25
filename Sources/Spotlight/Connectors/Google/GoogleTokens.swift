import Foundation

// The one place that holds the signed-in Google accounts' tokens, loads and
// saves them in the store, and refreshes access tokens when they expire.
// An actor, so Gmail and Drive syncing at the same time can't both refresh.
actor GoogleTokens {
    private let oauth: GoogleOAuth
    private let store: any CredentialStore
    private let now: @Sendable () -> Date
    // Logins already read from the store. Reading the Keychain can make macOS
    // ask for permission, so each account is read once per launch, not on
    // every request.
    private var cache: [String: GoogleCredentials] = [:]

    init(
        oauth: GoogleOAuth = GoogleOAuth(), store: any CredentialStore = KeychainStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.oauth = oauth
        self.store = store
        self.now = now
    }

    // Every signed-in account's email.
    func emails() -> [String] {
        (try? store.emails()) ?? []
    }

    // Each account's profile picture, for the ones that have one.
    func pictureURLs() -> [String: URL] {
        var urls: [String: URL] = [:]
        for email in emails() {
            if let url = (try? load(email))?.pictureURL { urls[email] = url }
        }
        return urls
    }

    func save(_ credentials: GoogleCredentials) throws {
        try store.save(credentials)
        cache[credentials.email] = credentials
    }

    private func load(_ email: String) throws -> GoogleCredentials? {
        if let cached = cache[email] { return cached }
        let loaded = try store.load(email)
        cache[email] = loaded
        return loaded
    }

    // A usable access token for `email`, refreshing it first if it has expired.
    func accessToken(for email: String) async throws -> String {
        guard var credentials = try load(email) else { throw GoogleAuthError.signInRequired }
        if credentials.isExpired(at: now()) {
            do {
                credentials = try await oauth.refresh(credentials, now: now())
            } catch GoogleAuthError.signInRequired {
                // The refresh token is dead; forget it so the UI offers to reconnect.
                try? store.delete(email)
                cache[email] = nil
                throw GoogleAuthError.signInRequired
            }
            try save(credentials)
        }
        return credentials.accessToken
    }

    // Throws if the login can't be removed, so the UI can say so instead of
    // silently leaving the account connected.
    func signOut(_ email: String) async throws {
        if let credentials = try? load(email) {
            await oauth.revoke(credentials)
        }
        try store.delete(email)
        cache[email] = nil
    }
}
