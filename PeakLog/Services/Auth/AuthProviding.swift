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

protocol AuthProviding: TokenProviding {
    func restoreUser() async -> AuthedUser?
    func stateChanges() -> AsyncStream<AuthProviderEvent>
    func signInWithApple(_ credential: AppleSignInCredential) async throws -> AuthedUser
    #if DEBUG
    func signIn(email: String, password: String) async throws -> AuthedUser
    #endif
    func signOut() async
}
