import Foundation

// What Google gives us after sign-in. Codable = can be turned into JSON and
// back, which is how it's stored in the Keychain.
struct GoogleCredentials: Codable, Sendable, Equatable {
    var email: String
    // Short-lived (about an hour); sent with every API request.
    var accessToken: String
    // Long-lived; trades for a new access token when the old one expires.
    var refreshToken: String
    var expiresAt: Date
    var scopes: [String]
    // Your Google profile picture. Optional, so logins saved before we asked
    // for it still load (Codable reads a missing optional as nil).
    var pictureURL: URL? = nil

    // A minute of slack, so a token doesn't expire mid-request.
    func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < 60
    }
}

// Where credentials are kept, one entry per Google account, found by its
// email. A protocol so tests can use memory instead of your real Keychain.
protocol CredentialStore: Sendable {
    // Every signed-in account, sorted.
    func emails() throws -> [String]
    func load(_ email: String) throws -> GoogleCredentials?
    // Adds the account, or replaces it if that email is already signed in.
    func save(_ credentials: GoogleCredentials) throws
    func delete(_ email: String) throws
}
