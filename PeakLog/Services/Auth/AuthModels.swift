import Foundation

/// The authenticated user identity the app cares about. Deliberately minimal —
/// profile details live in `profiles`, fetched separately once signed in.
nonisolated struct AuthedUser: Equatable, Sendable, Codable {
    let id: String          // auth.users.id (uuid), also the RLS subject
    let email: String?
}

nonisolated struct AppleSignInCredential: Equatable, Sendable {
    let idToken: String
    let nonce: String
    let fullName: String?
    let givenName: String?
    let familyName: String?

    init(
        idToken: String,
        nonce: String,
        fullName: String? = nil,
        givenName: String? = nil,
        familyName: String? = nil
    ) {
        self.idToken = idToken
        self.nonce = nonce
        self.fullName = fullName
        self.givenName = givenName
        self.familyName = familyName
    }
}

/// The classified, user-facing outcome of a failed auth attempt.
///
/// Deliberately a closed set of cases with no associated payload. `AppAuthError`
/// carries the raw backend text in `.server(message:)`, and that text must never
/// reach the login screen — a Supabase auth error can name internal endpoints,
/// providers or policies. Publishing this type instead of a free-form `String`
/// makes the redaction a property of the type rather than a convention someone
/// can quietly break later (Issue #46).
nonisolated enum AuthDisplayError: Equatable, Sendable, CaseIterable {
    case signInFailed
    case network
    case notConfigured
    case appleAuthorizationFailed

    var localizedMessage: String {
        switch self {
        case .signInFailed:
            return String(localized: "auth.error.sign_in_failed")
        case .network:
            return String(localized: "auth.error.network")
        case .notConfigured:
            return String(localized: "auth.error.not_configured")
        case .appleAuthorizationFailed:
            return String(localized: "auth.error.apple_authorization_failed")
        }
    }

    /// Collapses a domain error into what the user is allowed to see. `nil`
    /// means "say nothing" — a user-initiated cancel is not a failure.
    init?(_ error: AppAuthError) {
        switch error {
        case .invalidCredentials:
            self = .signInFailed
        case .network:
            self = .network
        case .notConfigured:
            self = .notConfigured
        // The server's own wording is dropped on purpose; a failed sign-in
        // reads the same to the user however the backend phrased it.
        case .server:
            self = .signInFailed
        case .cancelled:
            return nil
        }
    }
}

nonisolated enum AppAuthError: Error, Equatable, Sendable {
    case invalidCredentials
    case network
    case server(message: String)
    case notConfigured
    case cancelled

    var isRetryable: Bool {
        switch self {
        case .network, .server: return true
        case .invalidCredentials, .notConfigured, .cancelled: return false
        }
    }
}
