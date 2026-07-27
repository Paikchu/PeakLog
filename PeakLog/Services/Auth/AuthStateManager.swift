import Combine
import Foundation

private struct AuthTokenProvider: TokenProviding {
    let auth: AuthStateManager

    func validToken() async throws -> String {
        try await auth.validToken()
    }
}

enum AuthGateState: Equatable {
    case checking
    case signedOut
    case signedIn(AuthedUser)
    case localOnly
}

@MainActor
final class AuthStateManager: ObservableObject {
    @Published private(set) var state: AuthGateState = .checking
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private let provider: AuthProviding
    private var eventTask: Task<Void, Never>?

    init(provider: AuthProviding = SupabaseAuthProvider()) {
        self.provider = provider
    }

    deinit {
        eventTask?.cancel()
    }

    var currentUserId: String? {
        if case let .signedIn(user) = state { return user.id }
        return nil
    }

    func restore() async {
        observeProvider()
        if let user = await provider.restoreUser() {
            state = .signedIn(user)
        } else {
            state = .signedOut
        }
    }

    func validToken() async throws -> String {
        do {
            return try await provider.validToken()
        } catch AppAuthError.invalidCredentials {
            state = .signedOut
            throw AppAuthError.invalidCredentials
        } catch {
            throw error
        }
    }

    func signIn(email: String, password: String) async {
        guard !isBusy else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            errorMessage = String(localized: "auth.error.missing_fields")
            return
        }

        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            state = .signedIn(
                try await provider.signIn(email: trimmedEmail, password: password)
            )
        } catch let error as AppAuthError {
            errorMessage = message(for: error)
        } catch {
            errorMessage = message(for: .network)
        }
    }

    func signOut() async {
        await provider.signOut()
        errorMessage = nil
        state = .signedOut
    }

    #if DEBUG
    func enterLocalMode() {
        errorMessage = nil
        state = .localOnly
    }
    #endif

    func makeTokenProvider() -> TokenProviding {
        AuthTokenProvider(auth: self)
    }

    private func observeProvider() {
        guard eventTask == nil else { return }
        let changes = provider.stateChanges()
        eventTask = Task { [weak self] in
            for await event in changes {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: AuthProviderEvent) {
        switch event {
        case .initialSession(let user):
            state = user.map(AuthGateState.signedIn) ?? .signedOut
        case .signedIn(let user), .tokenRefreshed(let user):
            state = .signedIn(user)
        case .signedOut:
            state = .signedOut
        }
    }

    private func message(for error: AppAuthError) -> String {
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
