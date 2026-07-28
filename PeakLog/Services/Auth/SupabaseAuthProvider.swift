import Foundation
import Supabase

nonisolated struct SupabaseAuthProvider: AuthProviding {
    private let client: SupabaseClient
    private let clearPersistedSession: @Sendable () throws -> Void

    init() {
        self = SupabaseClientFactory().makeAuthProvider()
    }

    init(
        client: SupabaseClient,
        clearPersistedSession: @escaping @Sendable () throws -> Void
    ) {
        self.client = client
        self.clearPersistedSession = clearPersistedSession
    }

    func restoreUser() async -> AuthedUser? {
        guard let stored = client.auth.currentSession else { return nil }
        guard stored.isExpired else { return Self.user(from: stored) }

        do {
            return Self.user(from: try await client.auth.session)
        } catch {
            let mapped = Self.map(error)
            if mapped == .invalidCredentials {
                await signOut()
                return nil
            }
            return Self.user(from: stored)
        }
    }

    func stateChanges() -> AsyncStream<AuthProviderEvent> {
        let upstream = client.auth.authStateChanges
        return AsyncStream { continuation in
            let task = Task {
                for await change in upstream {
                    guard let event = Self.event(change.event, session: change.session) else { continue }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func signIn(email: String, password: String) async throws -> AuthedUser {
        do {
            return Self.user(from: try await client.auth.signIn(email: email, password: password))
        } catch {
            throw Self.map(error)
        }
    }

    func signOut() async {
        defer { try? clearPersistedSession() }
        try? await client.auth.signOut(scope: .local)
    }

    func validToken() async throws -> String {
        guard client.auth.currentSession != nil else {
            throw AppAuthError.invalidCredentials
        }

        do {
            return try await client.auth.session.accessToken
        } catch {
            let mapped = Self.map(error)
            if mapped == .invalidCredentials {
                await signOut()
            }
            throw mapped
        }
    }

    private static func user(from session: Session) -> AuthedUser {
        AuthedUser(
            id: session.user.id.uuidString.lowercased(),
            email: session.user.email
        )
    }

    private static func event(
        _ event: AuthChangeEvent,
        session: Session?
    ) -> AuthProviderEvent? {
        switch event {
        case .initialSession:
            return .initialSession(session.map { user(from: $0) })
        case .signedIn, .userUpdated, .mfaChallengeVerified, .passwordRecovery:
            return session.map { .signedIn(user(from: $0)) }
        case .signedOut, .userDeleted:
            return .signedOut
        case .tokenRefreshed:
            return session.map { .tokenRefreshed(user(from: $0)) }
        }
    }

    private static func map(_ error: Error) -> AppAuthError {
        if error is CancellationError {
            return .cancelled
        }
        if error is URLError {
            return .network
        }
        guard let error = error as? AuthError else {
            return .network
        }

        switch error {
        case .sessionMissing:
            return .invalidCredentials
        case .api(let message, _, _, let response):
            if [400, 401, 403].contains(response.statusCode) {
                return .invalidCredentials
            }
            return .server(message: message)
        default:
            return .server(message: error.message)
        }
    }
}
