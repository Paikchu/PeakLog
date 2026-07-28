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
    private var authenticationGeneration: UInt = 0
    private var acceptsProviderSignedInEvents = true

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
        acceptsProviderSignedInEvents = true
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
            invalidateAuthenticationOperations()
            state = .signedOut
            throw AppAuthError.invalidCredentials
        } catch {
            throw error
        }
    }

    func signInWithApple(_ credential: AppleSignInCredential) async {
        guard !isBusy else { return }

        let generation = beginAuthenticationOperation()
        isBusy = true
        errorMessage = nil
        defer {
            if generation == authenticationGeneration {
                isBusy = false
            }
        }

        do {
            let user = try await provider.signInWithApple(credential)
            guard generation == authenticationGeneration else { return }
            acceptsProviderSignedInEvents = true
            state = .signedIn(user)
        } catch let error as AppAuthError {
            guard generation == authenticationGeneration else { return }
            errorMessage = message(for: error)
        } catch {
            guard generation == authenticationGeneration else { return }
            errorMessage = message(for: .network)
        }
    }

    #if DEBUG
    func signIn(email: String, password: String) async {
        guard !isBusy else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            errorMessage = String(localized: "auth.error.sign_in_failed")
            return
        }

        let generation = beginAuthenticationOperation()
        isBusy = true
        errorMessage = nil
        defer {
            if generation == authenticationGeneration {
                isBusy = false
            }
        }

        do {
            let user = try await provider.signIn(email: trimmedEmail, password: password)
            guard generation == authenticationGeneration else { return }
            acceptsProviderSignedInEvents = true
            state = .signedIn(user)
        } catch let error as AppAuthError {
            guard generation == authenticationGeneration else { return }
            errorMessage = message(for: error)
        } catch {
            guard generation == authenticationGeneration else { return }
            errorMessage = message(for: .network)
        }
    }
    #endif

    func clearSignInError() {
        errorMessage = nil
    }

    func reportAppleAuthorizationFailure() {
        errorMessage = String(localized: "auth.error.apple_authorization_failed")
    }

    func signOut() async {
        invalidateAuthenticationOperations()
        await provider.signOut()
        errorMessage = nil
        state = .signedOut
    }

    #if DEBUG
    func enterLocalMode() {
        invalidateAuthenticationOperations()
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
            guard let user else {
                invalidateAuthenticationOperations()
                state = .signedOut
                return
            }
            guard acceptsProviderSignedInEvents else { return }
            state = .signedIn(user)
        case .signedIn(let user), .tokenRefreshed(let user):
            guard acceptsProviderSignedInEvents else { return }
            state = .signedIn(user)
        case .signedOut:
            invalidateAuthenticationOperations()
            state = .signedOut
        }
    }

    private func beginAuthenticationOperation() -> UInt {
        authenticationGeneration &+= 1
        acceptsProviderSignedInEvents = false
        return authenticationGeneration
    }

    private func invalidateAuthenticationOperations() {
        authenticationGeneration &+= 1
        acceptsProviderSignedInEvents = false
        isBusy = false
    }

    private func message(for error: AppAuthError) -> String? {
        switch error {
        case .invalidCredentials:
            return String(localized: "auth.error.sign_in_failed")
        case .network:
            return String(localized: "auth.error.network")
        case .notConfigured:
            return String(localized: "auth.error.not_configured")
        case .server:
            return String(localized: "auth.error.sign_in_failed")
        case .cancelled:
            return nil
        }
    }
}
