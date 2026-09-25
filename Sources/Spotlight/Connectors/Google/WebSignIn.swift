import AuthenticationServices
import Foundation

// Shows Apple's sign-in sheet (ASWebAuthenticationSession) for a URL and waits
// until it's redirected to `callbackScheme`. It's a real browser, so Google
// allows it (Google blocks sign-in inside embedded web views), and it can reuse
// your existing Google login.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        // withCheckedThrowingContinuation turns a callback-style API into one we
        // can `await`: we get a `continuation` and resume it exactly once.
        try await withCheckedThrowingContinuation { continuation in
            // @Sendable: AuthenticationServices calls this from a background thread.
            // Without it, Swift assumes the closure belongs to the main actor (like
            // the rest of this class) and deliberately crashes when it isn't on the
            // main thread. It only resumes the continuation, which is thread-safe.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) {
                @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GoogleAuthError.missingCode)
                }
            }
            session.presentationContextProvider = self
            self.session = session  // keep it alive until it finishes
            session.start()
        }
    }

    // Which window the sheet attaches to. Required by the protocol, which calls
    // it from outside the main actor, hence `nonisolated` + assumeIsolated.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? ASPresentationAnchor() }
    }
}
