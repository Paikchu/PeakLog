import Combine
import Foundation
import OSLog

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
    /// Classified, already-redacted failure. `private(set)` so nothing outside
    /// this type can inject an unclassified message (Issue #46).
    @Published private(set) var displayError: AuthDisplayError?

    /// Convenience for callers that just want the string. Derived, so there is
    /// still exactly one place that decides what the user is told.
    var errorMessage: String? { displayError?.localizedMessage }

    private static let logger = Logger(subsystem: "com.max.PeakLog", category: "Auth")

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
        displayError = nil
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
            report(error)
        } catch {
            guard generation == authenticationGeneration else { return }
            report(.network)
        }
    }

    #if DEBUG
    func signIn(email: String, password: String) async {
        guard !isBusy else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            displayError = .signInFailed
            return
        }

        let generation = beginAuthenticationOperation()
        isBusy = true
        displayError = nil
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
            report(error)
        } catch {
            guard generation == authenticationGeneration else { return }
            report(.network)
        }
    }
    #endif

    func clearSignInError() {
        displayError = nil
    }

    func reportAppleAuthorizationFailure() {
        displayError = .appleAuthorizationFailed
    }

    func signOut() async {
        invalidateAuthenticationOperations()
        await provider.signOut()
        displayError = nil
        state = .signedOut
    }

    #if DEBUG
    func enterLocalMode() {
        invalidateAuthenticationOperations()
        displayError = nil
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

    /// Classifies for the UI and keeps the unredacted error for the developer.
    /// The raw text is logged `.private`, so it stays available in a local
    /// debug session but is redacted in any log the device hands out.
    private func report(_ error: AppAuthError) {
        Self.logger.error("auth failure: \(String(describing: error), privacy: .private)")
        displayError = AuthDisplayError(error)
    }
}
