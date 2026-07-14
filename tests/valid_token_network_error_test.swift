import Foundation

// Standalone driver for the validToken() network-vs-invalidCredentials fix.
// Compile: swiftc -parse-as-library \
//   PeakLog/Services/Auth/AuthModels.swift \
//   PeakLog/Services/Auth/AuthProviding.swift \
//   PeakLog/Services/Auth/AuthSessionStore.swift \
//   PeakLog/Services/SupabaseConfig.swift \
//   PeakLog/Services/Auth/SupabaseAuthProvider.swift \
//   PeakLog/Services/Auth/AuthStateManager.swift \
//   tests/valid_token_network_error_test.swift -o /tmp/valid_token_test && /tmp/valid_token_test

private func session(accessToken: String, refreshToken: String, expiresAt: TimeInterval) -> AuthSession {
    AuthSession(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: Date(timeIntervalSince1970: expiresAt),
        user: AuthedUser(id: "user-1", email: "user@example.com")
    )
}

private struct FailingRefreshProvider: AuthProviding {
    let error: AuthError
    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthError.network }
    func refresh(refreshToken: String) async throws -> AuthSession { throw error }
    func signOut(accessToken: String) async {}
}

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

@main
struct Runner {
    static func main() async {
        // Mirrors testValidTokenKeepsSessionOnNetworkFailure
        do {
            let expired = session(accessToken: "expired", refreshToken: "refresh-1", expiresAt: 5_000)
            let store = InMemoryAuthSessionStore(seed: expired)
            let manager = await AuthStateManager(
                provider: FailingRefreshProvider(error: AuthError.network),
                store: store
            )

            await manager.restore(now: Date(timeIntervalSince1970: 0))

            var rethrewNetwork = false
            do {
                _ = try await manager.validToken(now: Date(timeIntervalSince1970: 10_000))
            } catch AuthError.network {
                rethrewNetwork = true
            } catch {
                rethrewNetwork = false
            }
            check(rethrewNetwork, "validToken rethrows AuthError.network instead of invalidCredentials")

            let state = await manager.state
            if case .signedIn(let user) = state {
                check(user.id == "user-1", "session preserved as signedIn after network failure")
            } else {
                check(false, "session preserved as signedIn after network failure (got \(state))")
            }
            check(store.load() != nil, "local session not cleared on network failure")
        }

        // Mirrors testValidTokenSignsOutOnInvalidCredentials
        do {
            let expired = session(accessToken: "expired", refreshToken: "refresh-1", expiresAt: 5_000)
            let store = InMemoryAuthSessionStore(seed: expired)
            let manager = await AuthStateManager(
                provider: FailingRefreshProvider(error: AuthError.invalidCredentials),
                store: store
            )

            await manager.restore(now: Date(timeIntervalSince1970: 0))

            var threwInvalidCredentials = false
            do {
                _ = try await manager.validToken(now: Date(timeIntervalSince1970: 10_000))
            } catch AuthError.invalidCredentials {
                threwInvalidCredentials = true
            } catch {
                threwInvalidCredentials = false
            }
            check(threwInvalidCredentials, "validToken throws invalidCredentials when refresh token is rejected")

            let state = await manager.state
            check(state == .signedOut, "state is signedOut after invalidCredentials (got \(state))")
            check(store.load() == nil, "local session cleared when refresh token is rejected")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
