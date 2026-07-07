import Foundation

/// The authenticated user identity the app cares about. Deliberately minimal —
/// profile details live in `profiles`, fetched separately once signed in.
nonisolated struct AuthedUser: Equatable, Sendable, Codable {
    let id: String          // auth.users.id (uuid), also the RLS subject
    let email: String?
}

/// A live session: the tokens the app needs to authorize requests, plus the
/// user they belong to. Persisted so a returning user skips the login screen.
nonisolated struct AuthSession: Equatable, Sendable, Codable {
    let accessToken: String
    let refreshToken: String
    /// Absolute expiry of `accessToken`. Compared against `now` to decide when
    /// a refresh is due.
    let expiresAt: Date
    let user: AuthedUser

    /// A small skew keeps us from using a token that expires mid-flight.
    func isExpired(now: Date, skew: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(skew) >= expiresAt
    }
}

/// Provider-agnostic failure surface. The Supabase adapter maps transport and
/// GoTrue errors onto these; the UI only needs to distinguish "bad credentials"
/// from "try again".
nonisolated enum AuthError: Error, Equatable, Sendable {
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
