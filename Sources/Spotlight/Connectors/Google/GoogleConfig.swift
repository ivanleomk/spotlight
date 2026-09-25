import Foundation

// This app's registration with Google (Cloud project "Hojo", iOS OAuth client
// "Spotlight (macOS)"). A client ID is not a secret: it only says which app
// is asking. iOS-type clients have no client secret at all, which is why this
// can live in a public repo.
struct GoogleConfig: Sendable {
    var clientID = "1011333753769-6h94i8nt7fvenq3i5s5q21kg8c4ur8fi.apps.googleusercontent.com"

    // Who you are (email; profile = name and picture), plus read-only access to
    // every service we can index; we never change anything in your Google
    // account. All are asked for up front, because adding one later would mean
    // signing in again.
    var scopes = ["openid", "email", "profile"] + GoogleService.allCases.map(\.scope)

    // Google tells iOS-type clients to use their client ID reversed as a URL
    // scheme: "com.googleusercontent.apps.1011...". After sign-in, the browser is
    // sent to this address, and the sign-in sheet hands it back to us.
    var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }
    var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
}
