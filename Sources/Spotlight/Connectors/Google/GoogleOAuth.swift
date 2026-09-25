import Foundation

enum GoogleAuthError: Error, Equatable, CustomStringConvertible {
    case cancelled
    case stateMismatch
    case denied(String)
    case missingCode
    case missingRefreshToken
    case missingEmail
    // The refresh token no longer works (revoked, or Google's 7-day limit for
    // apps in Testing mode). The only fix is signing in again.
    case signInRequired
    case server(status: Int, message: String)

    var description: String {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .stateMismatch: "Sign-in reply didn't match the request."
        case .denied(let reason): "Google declined: \(reason)."
        case .missingCode: "Google's reply had no sign-in code."
        case .missingRefreshToken: "Google didn't send a refresh token."
        case .missingEmail: "Google didn't say which account signed in."
        case .signInRequired: "Please connect your Google account again."
        case .server(let status, let message): "Google error \(status): \(message)"
        }
    }
}

// The OAuth "authorization code with PKCE" flow for an installed app:
//   1. Open `authorizationURL` in a browser sheet; you sign in and approve.
//   2. Google redirects to our callback scheme with a one-time code.
//   3. `exchange` trades the code (plus the PKCE verifier) for tokens.
//   4. Later, `refresh` trades the refresh token for a new access token.
struct GoogleOAuth: Sendable {
    var config = GoogleConfig()
    var http: any HTTPClient = URLSession.shared

    func authorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: GoogleConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // select_account: always show Google's account picker, so "Add
            // Account" can pick a different one. consent: always show the consent
            // screen, so Google always sends a refresh token (it skips it on
            // repeat sign-ins otherwise).
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        return components.url!
    }

    // Pulls the one-time code out of the redirect, e.g.
    // "com.googleusercontent.apps.123:/oauth2redirect?state=xyz&code=4/0Ab..."
    static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") { throw GoogleAuthError.denied(error) }
        // `state` is a random value we sent; getting it back proves this reply
        // belongs to the sign-in we started.
        guard value("state") == expectedState else { throw GoogleAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw GoogleAuthError.missingCode }
        return code
    }

    func exchange(code: String, pkce: PKCE, now: Date = Date()) async throws -> GoogleCredentials {
        let response = try await tokenRequest([
            "client_id": config.clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI,
        ])
        guard let refreshToken = response.refresh_token else { throw GoogleAuthError.missingRefreshToken }
        let identity = response.id_token.flatMap(Self.identity(fromIDToken:))
        guard let identity else { throw GoogleAuthError.missingEmail }
        return GoogleCredentials(
            email: identity.email, accessToken: response.access_token, refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(response.expires_in),
            scopes: response.scope?.split(separator: " ").map(String.init) ?? config.scopes,
            pictureURL: identity.picture)
    }

    func refresh(_ credentials: GoogleCredentials, now: Date = Date()) async throws -> GoogleCredentials {
        let response: TokenResponse
        do {
            response = try await tokenRequest([
                "client_id": config.clientID,
                "grant_type": "refresh_token",
                "refresh_token": credentials.refreshToken,
            ])
        } catch GoogleAuthError.server(400, let message) where message.contains("invalid_grant") {
            throw GoogleAuthError.signInRequired
        }
        var updated = credentials
        updated.accessToken = response.access_token
        updated.expiresAt = now.addingTimeInterval(response.expires_in)
        // Google usually keeps the same refresh token, but may send a new one.
        if let newRefresh = response.refresh_token { updated.refreshToken = newRefresh }
        return updated
    }

    // Tells Google to cancel our access. Best effort: if it fails, we still
    // forget the tokens locally.
    func revoke(_ credentials: GoogleCredentials) async {
        _ = try? await http.send(.form(GoogleConfig.revokeURL, ["token": credentials.refreshToken]))
    }

    // The JSON Google's token endpoint returns. Property names match the JSON
    // keys exactly, so Codable needs no extra mapping.
    struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        let id_token: String?
        let scope: String?
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        let (data, response) = try await http.send(.form(GoogleConfig.tokenURL, fields))
        guard response.statusCode == 200 else {
            throw GoogleAuthError.server(
                status: response.statusCode, message: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // Who signed in, from the ID token.
    struct Identity: Equatable {
        var email: String
        var picture: URL?
    }

    // An ID token is a JWT: three base64 parts, "header.payload.signature". The
    // payload is JSON about who signed in. It came straight from Google over
    // HTTPS, so we can read it without checking the signature ourselves.
    static func identity(fromIDToken token: String) -> Identity? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)  // restore padding
        guard let data = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let email = claims["email"] as? String else { return nil }
        return Identity(email: email, picture: (claims["picture"] as? String).flatMap(URL.init(string:)))
    }
}
