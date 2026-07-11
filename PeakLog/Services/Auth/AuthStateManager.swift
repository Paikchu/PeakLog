import Foundation
import Combine

/// Bridges the `@MainActor` auth manager to the `Sendable` `TokenProviding`
/// seam the data layer expects. Holding the manager (itself `Sendable`) is safe;
/// the `await` hops to the main actor for the actual refresh.
private struct AuthTokenProvider: TokenProviding {
    let auth: AuthStateManager
    func validToken() async throws -> String {
        try await auth.validToken()
    }
}

/// The app's authentication gate state. `RootView` renders off this.
enum AuthGateState: Equatable {
    /// Restoring a persisted session on launch — show a splash, not the login.
    case checking
    /// No valid session — show `AuthView`.
    case signedOut
    /// Authenticated against Supabase — show the app, sync is allowed.
    case signedIn(AuthedUser)
    /// DEBUG-only local mode: seed data, no cloud, no sync. Never reachable in
    /// release builds. Lets development iterate without a live account.
    case localOnly
}

/// Owns the session lifecycle: restore on launch, sign in / out, refresh.
/// Provider-agnostic — it drives `AuthProviding` and never mentions Supabase.
@MainActor
final class AuthStateManager: ObservableObject {
    @Published private(set) var state: AuthGateState = .checking
    @Published private(set) var isBusy: Bool = false
    @Published var errorMessage: String?

    private let provider: AuthProviding
    private let store: AuthSessionStoring
    private var session: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?

    init(
        provider: AuthProviding = SupabaseAuthProvider(),
        store: AuthSessionStoring = KeychainAuthSessionStore()
    ) {
        self.provider = provider
        self.store = store
    }

    /// The RLS subject for the signed-in user, if any. Step 4's remote services
    /// read this to scope requests.
    var currentUserId: String? {
        if case let .signedIn(user) = state { return user.id }
        return nil
    }

    // MARK: - Launch restore

    /// Restore a persisted session. Valid → straight in; expired → refresh;
    /// refresh failure or nothing stored → signed out.
    func restore(now: Date = Date()) async {
        guard let stored = store.load() else {
            state = .signedOut
            return
        }

        if !stored.isExpired(now: now) {
            session = stored
            state = .signedIn(stored.user)
            return
        }

        do {
            let refreshed = try await provider.refresh(refreshToken: stored.refreshToken)
            persist(refreshed)
        } catch {
            store.clear()
            session = nil
            state = .signedOut
        }
    }

    // MARK: - Token vending

    /// A valid access token, refreshed if the cached one is within the skew
    /// window. Throws `.invalidCredentials` if there is no session or the
    /// refresh token is dead — the caller should treat that as signed-out.
    func validToken(now: Date = Date()) async throws -> String {
        guard let current = session else { throw AuthError.invalidCredentials }
        if !current.isExpired(now: now) { return current.accessToken }

        do {
            if let refreshTask {
                let refreshed = try await refreshTask.value
                persist(refreshed)
                return refreshed.accessToken
            } else {
                let provider = provider
                let token = current.refreshToken
                let task = Task { try await provider.refresh(refreshToken: token) }
                refreshTask = task
                defer { refreshTask = nil }
                let refreshed = try await task.value
                persist(refreshed)
                return refreshed.accessToken
            }
        } catch {
            if session?.refreshToken == current.refreshToken {
                store.clear()
                session = nil
                state = .signedOut
            }
            throw AuthError.invalidCredentials
        }
    }

    // MARK: - Sign in / out

    func signIn(email: String, password: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            errorMessage = String(localized: "auth.error.missing_fields")
            return
        }

        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let newSession = try await provider.signIn(email: trimmedEmail, password: password)
            persist(newSession)
        } catch let error as AuthError {
            errorMessage = message(for: error)
        } catch {
            errorMessage = message(for: .network)
        }
    }

    func signOut() async {
        if let token = session?.accessToken {
            await provider.signOut(accessToken: token)
        }
        store.clear()
        session = nil
        errorMessage = nil
        state = .signedOut
    }

    #if DEBUG
    /// Enter local seed-data mode without authenticating. DEBUG only.
    func enterLocalMode() {
        errorMessage = nil
        state = .localOnly
    }
    #endif

    // MARK: - Helpers

    private func persist(_ newSession: AuthSession) {
        session = newSession
        store.save(newSession)
        state = .signedIn(newSession.user)
    }

    /// A `Sendable` token source the background data layer can hold without
    /// capturing the `@MainActor` manager's mutable state directly.
    func makeTokenProvider() -> TokenProviding {
        AuthTokenProvider(auth: self)
    }

    private func message(for error: AuthError) -> String {
        switch error {
        case .invalidCredentials:
            return String(localized: "auth.error.invalid_credentials")
        case .network:
            return String(localized: "auth.error.network")
        case .notConfigured:
            return String(localized: "auth.error.not_configured")
        case .server(let message):
            return message
        case .cancelled:
            return String(localized: "auth.error.network")
        }
    }
}
