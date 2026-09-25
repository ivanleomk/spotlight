import Foundation
import Security
import Testing

@testable import Spotlight

// MARK: - Fakes

// Answers every request with whatever `respond` returns, and remembers the
// requests so tests can check what was sent.
struct FakeHTTP: HTTPClient {
    actor Log {
        var requests: [URLRequest] = []
        func add(_ request: URLRequest) { requests.append(request) }
    }

    let log = Log()
    let respond: @Sendable (URLRequest) -> (status: Int, body: String)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await log.add(request)
        let (status, body) = respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

extension URLRequest {
    // The form body as a dictionary, e.g. ["grant_type": "refresh_token"].
    var formFields: [String: String] {
        let body = String(decoding: httpBody ?? Data(), as: UTF8.self)
        let items = URLComponents(string: "?" + body)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

// Keeps credentials in memory. A lock guards the value because the protocol's
// methods may be called from different threads; `@unchecked Sendable` is us
// promising the compiler that the lock makes that safe.
final class InMemoryStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var byEmail: [String: GoogleCredentials] = [:]

    init(_ accounts: GoogleCredentials...) {
        for account in accounts { byEmail[account.email] = account }
    }

    func emails() throws -> [String] { lock.withLock { byEmail.keys.sorted() } }
    func load(_ email: String) throws -> GoogleCredentials? { lock.withLock { byEmail[email] } }
    func save(_ credentials: GoogleCredentials) throws { lock.withLock { byEmail[credentials.email] = credentials } }
    func delete(_ email: String) throws { lock.withLock { byEmail[email] = nil } }
}

// A fake ID token whose payload says who signed in (signature not needed).
func idToken(email: String, picture: String = "https://lh3.googleusercontent.com/a/me") -> String {
    let payload = PKCE.base64URL(Data(#"{"email":"\#(email)","picture":"\#(picture)","sub":"123"}"#.utf8))
    return "eyJhbGciOiJSUzI1NiJ9.\(payload).signature"
}

let sampleCredentials = GoogleCredentials(
    email: "me@example.com", accessToken: "old-access", refreshToken: "refresh-1",
    expiresAt: Date(timeIntervalSince1970: 1_000), scopes: ["email"])

// MARK: - Tests

@Suite struct PKCETests {
    // The worked example from the PKCE standard (RFC 7636, appendix B).
    @Test func challengeMatchesTheStandardsExample() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomStringsAreURLSafeAndDifferent() {
        let a = PKCE.randomString(), b = PKCE.randomString()

        #expect(a.count == 43)
        #expect(a != b)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

@Suite struct GoogleOAuthTests {
    @Test func callbackSchemeIsTheReversedClientID() {
        let config = GoogleConfig(clientID: "123-abc.apps.googleusercontent.com")

        #expect(config.callbackScheme == "com.googleusercontent.apps.123-abc")
        #expect(config.redirectURI == "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    @Test func authorizationURLCarriesTheRequest() throws {
        let oauth = GoogleOAuth(config: GoogleConfig(clientID: "123-abc.apps.googleusercontent.com"))
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        let url = oauth.authorizationURL(pkce: pkce, state: "xyz")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(url.host == "accounts.google.com")
        #expect(query["client_id"] == "123-abc.apps.googleusercontent.com")
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "xyz")
        #expect(query["scope"]?.contains("gmail.readonly") == true)
        #expect(query["scope"]?.contains("calendar.readonly") == true)
        #expect(query["scope"]?.split(separator: " ").contains("profile") == true)
        // Always offer the account picker, so "Add Account" can choose another one.
        #expect(query["prompt"]?.contains("select_account") == true)
        // The verifier itself must never be in the URL.
        #expect(!url.absoluteString.contains(pkce.verifier))
    }

    @Test func readsTheCodeFromTheCallback() throws {
        let callback = URL(string: "com.googleusercontent.apps.1:/oauth2redirect?state=xyz&code=4/0Ab")!

        #expect(try GoogleOAuth.code(from: callback, expectedState: "xyz") == "4/0Ab")
    }

    @Test func rejectsBadCallbacks() {
        let base = "com.googleusercontent.apps.1:/oauth2redirect"

        #expect(throws: GoogleAuthError.stateMismatch) {
            try GoogleOAuth.code(from: URL(string: "\(base)?state=other&code=c")!, expectedState: "xyz")
        }
        #expect(throws: GoogleAuthError.denied("access_denied")) {
            try GoogleOAuth.code(from: URL(string: "\(base)?error=access_denied&state=xyz")!, expectedState: "xyz")
        }
        #expect(throws: GoogleAuthError.missingCode) {
            try GoogleOAuth.code(from: URL(string: "\(base)?state=xyz")!, expectedState: "xyz")
        }
    }

    @Test func readsWhoSignedInFromAnIDToken() {
        let identity = GoogleOAuth.identity(fromIDToken: idToken(email: "me@example.com"))

        #expect(identity?.email == "me@example.com")
        #expect(identity?.picture == URL(string: "https://lh3.googleusercontent.com/a/me"))
        #expect(GoogleOAuth.identity(fromIDToken: "not-a-jwt") == nil)
    }

    @Test func pictureIsOptional() {
        let payload = PKCE.base64URL(Data(#"{"email":"me@example.com"}"#.utf8))

        #expect(GoogleOAuth.identity(fromIDToken: "h.\(payload).s") == .init(email: "me@example.com", picture: nil))
    }

    // Logins saved before we stored pictures must still load.
    @Test func credentialsSavedWithoutAPictureStillDecode() throws {
        let old = #"{"email":"me@x.com","accessToken":"a","refreshToken":"r","expiresAt":0,"scopes":[]}"#

        let credentials = try JSONDecoder().decode(GoogleCredentials.self, from: Data(old.utf8))

        #expect(credentials.email == "me@x.com")
        #expect(credentials.pictureURL == nil)
    }

    @Test func exchangeSendsTheVerifierAndBuildsCredentials() async throws {
        let http = FakeHTTP { _ in
            (200, #"{"access_token":"a1","expires_in":3600,"refresh_token":"r1","id_token":"\#(idToken(email: "me@example.com"))","scope":"email openid"}"#)
        }
        let oauth = GoogleOAuth(http: http)
        let pkce = PKCE()
        let now = Date(timeIntervalSince1970: 0)

        let credentials = try await oauth.exchange(code: "the-code", pkce: pkce, now: now)

        #expect(credentials.email == "me@example.com")
        #expect(credentials.pictureURL == URL(string: "https://lh3.googleusercontent.com/a/me"))
        #expect(credentials.refreshToken == "r1")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 3600))
        #expect(credentials.scopes == ["email", "openid"])
        let sent = try #require(await http.log.requests.first?.formFields)
        #expect(sent["code"] == "the-code")
        #expect(sent["code_verifier"] == pkce.verifier)
        #expect(sent["grant_type"] == "authorization_code")
    }

    @Test func exchangeWithoutARefreshTokenFails() async {
        let http = FakeHTTP { _ in (200, #"{"access_token":"a1","expires_in":3600}"#) }

        await #expect(throws: GoogleAuthError.missingRefreshToken) {
            try await GoogleOAuth(http: http).exchange(code: "c", pkce: PKCE())
        }
    }

    @Test func refreshKeepsTheRefreshTokenWhenGoogleSendsNone() async throws {
        let http = FakeHTTP { _ in (200, #"{"access_token":"new-access","expires_in":100}"#) }

        let updated = try await GoogleOAuth(http: http).refresh(sampleCredentials, now: Date(timeIntervalSince1970: 0))

        #expect(updated.accessToken == "new-access")
        #expect(updated.refreshToken == "refresh-1")
        #expect(updated.expiresAt == Date(timeIntervalSince1970: 100))
    }

    @Test func deadRefreshTokenMeansSignInAgain() async {
        let http = FakeHTTP { _ in (400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#) }

        await #expect(throws: GoogleAuthError.signInRequired) {
            try await GoogleOAuth(http: http).refresh(sampleCredentials)
        }
    }

    @Test func formBodyEscapesPlusSigns() {
        let request = URLRequest.form(URL(string: "https://x.test")!, ["token": "a+b c"])

        #expect(request.formFields["token"] == "a+b c")
    }
}

@Suite struct GoogleTokensTests {
    @Test func freshTokenIsReturnedWithoutCallingGoogle() async throws {
        let http = FakeHTTP { _ in (500, "should not be called") }
        let tokens = GoogleTokens(
            oauth: GoogleOAuth(http: http), store: InMemoryStore(sampleCredentials),
            now: { Date(timeIntervalSince1970: 0) })

        #expect(try await tokens.accessToken(for: "me@example.com") == "old-access")
        #expect(await http.log.requests.isEmpty)
    }

    @Test func expiredTokenIsRefreshedAndSaved() async throws {
        let store = InMemoryStore(sampleCredentials)
        let http = FakeHTTP { _ in (200, #"{"access_token":"new-access","expires_in":3600}"#) }
        let tokens = GoogleTokens(
            oauth: GoogleOAuth(http: http), store: store, now: { Date(timeIntervalSince1970: 5_000) })

        #expect(try await tokens.accessToken(for: "me@example.com") == "new-access")
        #expect(try store.load("me@example.com")?.accessToken == "new-access")
    }

    @Test func deadRefreshTokenSignsOut() async throws {
        let store = InMemoryStore(sampleCredentials)
        let http = FakeHTTP { _ in (400, #"{"error":"invalid_grant"}"#) }
        let tokens = GoogleTokens(
            oauth: GoogleOAuth(http: http), store: store, now: { Date(timeIntervalSince1970: 5_000) })

        await #expect(throws: GoogleAuthError.signInRequired) { try await tokens.accessToken(for: "me@example.com") }
        #expect(try store.load("me@example.com") == nil)
        #expect(await tokens.emails().isEmpty)
    }

    @Test func notSignedInMeansSignInRequired() async {
        let tokens = GoogleTokens(oauth: GoogleOAuth(http: FakeHTTP { _ in (500, "") }), store: InMemoryStore())

        await #expect(throws: GoogleAuthError.signInRequired) { try await tokens.accessToken(for: "me@example.com") }
    }

    @Test func signOutRevokesAndForgets() async throws {
        let store = InMemoryStore(sampleCredentials)
        let http = FakeHTTP { _ in (200, "") }
        let tokens = GoogleTokens(oauth: GoogleOAuth(http: http), store: store)

        try await tokens.signOut("me@example.com")

        #expect(try store.load("me@example.com") == nil)
        let revoke = try #require(await http.log.requests.first)
        #expect(revoke.url == GoogleConfig.revokeURL)
        #expect(revoke.formFields["token"] == "refresh-1")
    }
}

@Suite struct MultipleAccountsTests {
    private func credentials(_ email: String, access: String) -> GoogleCredentials {
        GoogleCredentials(
            email: email, accessToken: access, refreshToken: "r-\(email)",
            expiresAt: Date(timeIntervalSince1970: 10_000), scopes: [])
    }

    @Test func eachAccountHasItsOwnTokens() async throws {
        let tokens = GoogleTokens(
            oauth: GoogleOAuth(http: FakeHTTP { _ in (500, "") }),
            store: InMemoryStore(credentials("work@x.com", access: "w"), credentials("home@x.com", access: "h")),
            now: { Date(timeIntervalSince1970: 0) })

        #expect(await tokens.emails() == ["home@x.com", "work@x.com"])
        #expect(try await tokens.accessToken(for: "work@x.com") == "w")
        #expect(try await tokens.accessToken(for: "home@x.com") == "h")
    }

    @Test func signingOutOneKeepsTheOther() async throws {
        let tokens = GoogleTokens(
            oauth: GoogleOAuth(http: FakeHTTP { _ in (200, "") }),
            store: InMemoryStore(credentials("work@x.com", access: "w"), credentials("home@x.com", access: "h")))

        try await tokens.signOut("work@x.com")

        #expect(await tokens.emails() == ["home@x.com"])
    }

    @Test func signingInTheSameAccountAgainReplacesIt() async throws {
        let store = InMemoryStore(credentials("me@x.com", access: "old"))
        let tokens = GoogleTokens(oauth: GoogleOAuth(http: FakeHTTP { _ in (500, "") }), store: store)

        try await tokens.save(credentials("me@x.com", access: "new"))

        #expect(await tokens.emails() == ["me@x.com"])
        #expect(try store.load("me@x.com")?.accessToken == "new")
    }

    @Test func eachServiceOfEachAccountIsItsOwnSource() {
        #expect(GoogleService.gmail.sourceID(for: "me@x.com") == "gmail:me@x.com")
        #expect(
            GoogleAccounts.sourceIDs(for: "me@x.com")
                == ["gmail:me@x.com", "drive:me@x.com", "calendar:me@x.com"])
    }
}

// A store that counts reads and can refuse deletes, like the Keychain does for
// items another program created.
final class StrictStore: CredentialStore, @unchecked Sendable {
    private let inner: InMemoryStore
    private let lock = NSLock()
    private var loads = 0
    var loadCount: Int { lock.withLock { loads } }

    init(_ accounts: GoogleCredentials...) {
        inner = InMemoryStore()
        for account in accounts { try? inner.save(account) }
    }

    func emails() throws -> [String] { try inner.emails() }
    func load(_ email: String) throws -> GoogleCredentials? {
        lock.withLock { loads += 1 }
        return try inner.load(email)
    }
    func save(_ credentials: GoogleCredentials) throws { try inner.save(credentials) }
    func delete(_ email: String) throws { throw KeychainStore.KeychainError(status: errSecInvalidOwnerEdit) }
}

@Suite struct KeychainFriendlinessTests {
    @Test func eachLoginIsReadFromTheStoreOnlyOnce() async throws {
        let store = StrictStore(sampleCredentials)
        let tokens = GoogleTokens(
            oauth: GoogleOAuth(http: FakeHTTP { _ in (500, "") }), store: store,
            now: { Date(timeIntervalSince1970: 0) })

        _ = try await tokens.accessToken(for: "me@example.com")
        _ = try await tokens.accessToken(for: "me@example.com")
        _ = await tokens.pictureURLs()

        #expect(store.loadCount == 1)
    }

    @Test func aRefusedDeleteIsReportedNotSwallowed() async throws {
        let tokens = GoogleTokens(
            oauth: GoogleOAuth(http: FakeHTTP { _ in (200, "") }), store: StrictStore(sampleCredentials))

        await #expect(throws: KeychainStore.KeychainError.self) { try await tokens.signOut("me@example.com") }
        #expect(await tokens.emails() == ["me@example.com"])
    }

    @Test func ownershipErrorExplainsTheFix() {
        let message = "\(KeychainStore.KeychainError(status: errSecInvalidOwnerEdit))"

        #expect(message.contains("Keychain Access"))
    }
}

@Suite struct GoogleServicePreferencesTests {
    // A throwaway preferences file, so tests don't touch the app's real settings.
    private func makePreferences() -> GoogleServicePreferences {
        let name = "SpotlightTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return GoogleServicePreferences(defaults: defaults)
    }

    @Test func newAccountsHaveEverythingOn() {
        #expect(makePreferences().enabled(for: "me@x.com") == Set(GoogleService.allCases))
    }

    @Test func remembersChoicesPerAccount() {
        let preferences = makePreferences()

        preferences.setEnabled([.gmail], for: "work@x.com")

        #expect(preferences.enabled(for: "work@x.com") == [.gmail])
        #expect(preferences.enabled(for: "home@x.com") == Set(GoogleService.allCases))
    }

    @Test func allOffIsRememberedAsAllOff() {
        let preferences = makePreferences()

        preferences.setEnabled([], for: "me@x.com")

        #expect(preferences.enabled(for: "me@x.com").isEmpty)
    }

    @Test func forgettingAnAccountResetsIt() {
        let preferences = makePreferences()
        preferences.setEnabled([.drive], for: "me@x.com")

        preferences.forget("me@x.com")

        #expect(preferences.enabled(for: "me@x.com") == Set(GoogleService.allCases))
    }
}

@Suite struct GoogleCardTests {
    @Test func subtitleCountsAccounts() {
        #expect(GoogleCard.subtitle(accountCount: 0).hasPrefix("Connect"))
        #expect(GoogleCard.subtitle(accountCount: 1) == "1 account")
        #expect(GoogleCard.subtitle(accountCount: 2) == "2 accounts")
    }

    @Test func avatarColorIsStablePerEmail() {
        #expect(Avatar.color(for: "me@x.com") == Avatar.color(for: "me@x.com"))
    }
}
