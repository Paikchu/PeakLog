import Foundation

/// The seam between the app and whatever authenticates it. Today the concrete
/// type is `SupabaseAuthProvider` (email + password against GoTrue). Adding
/// Sign in with Apple later means a new method here and a button in `AuthView` —
/// nothing above this protocol changes. See ADR-001 / Phase 0 §3.
/// Vends a currently-valid access token for authorizing cloud requests,
/// refreshing transparently when the cached one is near expiry. The data layer
/// depends on this, not on `AuthStateManager` directly.
protocol TokenProviding: Sendable {
    func validToken() async throws -> String
}

protocol AuthProviding: Sendable {
    /// Sign in with email + password, returning a live session on success.
    func signIn(email: String, password: String) async throws -> AuthSession

    /// Exchange a refresh token for a fresh session. Throws `.invalidCredentials`
    /// if the refresh token has been revoked, signalling a forced re-login.
    func refresh(refreshToken: String) async throws -> AuthSession

    /// Best-effort server-side revocation. Local session teardown happens
    /// regardless of whether this succeeds.
    func signOut(accessToken: String) async
}
