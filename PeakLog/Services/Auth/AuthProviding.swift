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
    func signIn(email: String, password: String) async throws -> AuthedUser
    func signOut() async
}
