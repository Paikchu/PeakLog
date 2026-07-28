import Foundation

/// The authenticated user identity the app cares about. Deliberately minimal —
/// profile details live in `profiles`, fetched separately once signed in.
nonisolated struct AuthedUser: Equatable, Sendable, Codable {
    let id: String          // auth.users.id (uuid), also the RLS subject
    let email: String?
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
