import CryptoKit
import Foundation

// PKCE ("pixie"): proof that the app finishing sign-in is the one that started
// it. We invent a random secret (the verifier), send Google only its SHA-256
// hash (the challenge), then reveal the verifier when trading the sign-in code
// for tokens. Anyone who intercepted the code can't use it without the verifier.
struct PKCE: Sendable {
    let verifier: String
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    init(verifier: String = PKCE.randomString()) {
        self.verifier = verifier
    }

    // 32 random bytes -> 43 URL-safe characters. Also used for the `state` value.
    static func randomString() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    // Base64 with the two characters that mean something in URLs swapped out,
    // and no "=" padding (RFC 7636).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
