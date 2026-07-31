import Foundation

/// Stands in for `SupabaseAuthProvider` when no Supabase endpoint could be
/// resolved (`SupabaseConfig.current == nil`).
///
/// The alternative was force-unwrapping the endpoint and trapping at launch.
/// A misconfigured build should still start, land on the login screen, and say
/// `auth.error.not_configured` when the user tries to sign in — that is a
/// diagnosable report, whereas a crash on launch is not (Issue #32).
nonisolated struct UnconfiguredAuthProvider: AuthProviding {
    func restoreUser() async -> AuthedUser? { nil }

    /// No events will ever arrive; finishing immediately lets
    /// `AuthStateManager.observeProvider`'s consumer task end instead of
    /// hanging on a stream that can never yield.
    func stateChanges() -> AsyncStream<AuthProviderEvent> {
        AsyncStream { $0.finish() }
    }

    func signInWithApple(_ credential: AppleSignInCredential) async throws -> AuthedUser {
        throw AppAuthError.notConfigured
    }

    #if DEBUG
    func signIn(email: String, password: String) async throws -> AuthedUser {
        throw AppAuthError.notConfigured
    }
    #endif

    func signOut() async {}

    func validToken() async throws -> String {
        throw AppAuthError.notConfigured
    }
}
