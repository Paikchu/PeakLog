import Foundation

/// Vends a currently-valid access token for authorizing cloud requests,
/// refreshing transparently through the Supabase SDK.
protocol TokenProviding: Sendable {
    func validToken() async throws -> String
}

nonisolated enum AuthProviderEvent: Sendable, Equatable {
    case initialSession(AuthedUser?)
    case signedIn(AuthedUser)
    case signedOut
    case tokenRefreshed(AuthedUser)
}

/// `nonisolated`: conforming to a `@MainActor` protocol would infer main-actor
/// isolation onto every auth provider (and every test double), which is wrong —
/// these are async facades over the Supabase SDK, not UI state. `TokenProviding`
/// is already `Sendable`, so implementations must be `Sendable` too.
nonisolated protocol AuthProviding: TokenProviding {
    func restoreUser() async -> AuthedUser?
    func stateChanges() -> AsyncStream<AuthProviderEvent>
    func signInWithApple(_ credential: AppleSignInCredential) async throws -> AuthedUser
    func signIn(email: String, password: String) async throws -> AuthedUser
    func signOut() async
}
