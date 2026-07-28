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
