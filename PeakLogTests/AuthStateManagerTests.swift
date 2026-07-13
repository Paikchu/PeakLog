import XCTest
@testable import PeakLog

final class AuthStateManagerTests: XCTestCase {
    func testConcurrentExpiredTokenRequestsUseOneRefresh() async throws {
        let oldSession = session(accessToken: "expired", refreshToken: "refresh-old", expiresAt: 1)
        let refreshedSession = session(accessToken: "fresh", refreshToken: "refresh-new", expiresAt: 20_000)
        let gate = RefreshGate()
        let provider = RefreshingProvider(gate: gate)
        let manager = await AuthStateManager(
            provider: provider,
            store: InMemoryAuthSessionStore(seed: oldSession)
        )

        await manager.restore(now: Date(timeIntervalSince1970: 0))
        let refreshNow = Date(timeIntervalSince1970: 10_000)
        async let first = manager.validToken(now: refreshNow)
        await gate.waitForRefresh()
        async let second = manager.validToken(now: refreshNow)
        await Task.yield()

        let refreshCountBeforeCompletion = await gate.refreshCount()
        XCTAssertEqual(refreshCountBeforeCompletion, 1)
        await gate.complete(with: refreshedSession)
        let firstToken = try await first
        let secondToken = try await second
        let refreshCountAfterCompletion = await gate.refreshCount()
        XCTAssertEqual(firstToken, "fresh")
        XCTAssertEqual(secondToken, "fresh")
        XCTAssertEqual(refreshCountAfterCompletion, 1)
    }

    // MARK: - Issue #9: signIn isBusy guard

    func testSignInGuardsAgainstDoubleSubmission() async throws {
        let gate = SignInGate()
        let provider = GatedSignInProvider(gate: gate)
        let manager = await AuthStateManager(
            provider: provider,
            store: InMemoryAuthSessionStore()
        )

        async let first: Void = manager.signIn(email: "user@example.com", password: "password")
        await gate.waitForSignIn()
        // The manager is already `isBusy` at this point (set synchronously
        // before the first `await`), so this second call must bail out
        // immediately without invoking the provider again.
        async let second: Void = manager.signIn(email: "user@example.com", password: "password")
        await Task.yield()

        let callsBeforeCompletion = await gate.callCount()
        XCTAssertEqual(callsBeforeCompletion, 1)

        await gate.complete(with: session(accessToken: "fresh", refreshToken: "refresh-new", expiresAt: 20_000))
        _ = await first
        _ = await second

        let callsAfterCompletion = await gate.callCount()
        XCTAssertEqual(callsAfterCompletion, 1)

        let state = await manager.state
        guard case .signedIn(let user) = state else {
            XCTFail("Expected signedIn state after the single successful sign-in")
            return
        }
        XCTAssertEqual(user.id, "user-1")
    }

    // MARK: - Issue #10: restore() network-vs-invalidCredentials handling

    func testRestoreKeepsLocalSessionOnNetworkFailure() async throws {
        let expired = session(accessToken: "expired", refreshToken: "refresh-1", expiresAt: 1)
        let store = InMemoryAuthSessionStore(seed: expired)
        let manager = await AuthStateManager(
            provider: FailingRefreshProvider(error: AuthError.network),
            store: store
        )

        await manager.restore(now: Date(timeIntervalSince1970: 10_000))

        let state = await manager.state
        guard case .signedIn(let user) = state else {
            XCTFail("Expected signedIn state to be preserved on a network failure")
            return
        }
        XCTAssertEqual(user.id, "user-1")
        XCTAssertNotNil(store.load(), "Local session must not be cleared on a network failure")

        // The still-expired session should be retried (not just discarded) on
        // the next token vend.
        do {
            _ = try await manager.validToken(now: Date(timeIntervalSince1970: 10_000))
            XCTFail("Expected validToken to retry the refresh and fail again while offline")
        } catch {
            // Expected: the underlying provider still fails.
        }
    }

    func testRestoreSignsOutOnInvalidCredentials() async throws {
        let expired = session(accessToken: "expired", refreshToken: "refresh-1", expiresAt: 1)
        let store = InMemoryAuthSessionStore(seed: expired)
        let manager = await AuthStateManager(
            provider: FailingRefreshProvider(error: AuthError.invalidCredentials),
            store: store
        )

        await manager.restore(now: Date(timeIntervalSince1970: 10_000))

        let state = await manager.state
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(store.load(), "Local session must be cleared when the refresh token is rejected")
    }

    private func session(accessToken: String, refreshToken: String, expiresAt: TimeInterval) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAt),
            user: AuthedUser(id: "user-1", email: "user@example.com")
        )
    }
}

private struct FailingRefreshProvider: AuthProviding {
    let error: AuthError

    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthError.network }
    func refresh(refreshToken: String) async throws -> AuthSession { throw error }
    func signOut(accessToken: String) async {}
}

private struct GatedSignInProvider: AuthProviding {
    let gate: SignInGate

    func signIn(email: String, password: String) async throws -> AuthSession {
        try await gate.signIn()
    }
    func refresh(refreshToken: String) async throws -> AuthSession { throw AuthError.network }
    func signOut(accessToken: String) async {}
}

private actor SignInGate {
    private var count = 0
    private var waiter: CheckedContinuation<AuthSession, Error>?
    private var signInStarted: CheckedContinuation<Void, Never>?

    func signIn() async throws -> AuthSession {
        count += 1
        signInStarted?.resume()
        signInStarted = nil
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func waitForSignIn() async {
        if count > 0 { return }
        await withCheckedContinuation { signInStarted = $0 }
    }

    func complete(with session: AuthSession) {
        waiter?.resume(returning: session)
        waiter = nil
    }

    func callCount() -> Int { count }
}

private struct RefreshingProvider: AuthProviding {
    let gate: RefreshGate

    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthError.network }
    func refresh(refreshToken: String) async throws -> AuthSession { try await gate.refresh() }
    func signOut(accessToken: String) async {}
}

private actor RefreshGate {
    private var count = 0
    private var waiter: CheckedContinuation<AuthSession, Error>?
    private var refreshStarted: CheckedContinuation<Void, Never>?

    func refresh() async throws -> AuthSession {
        count += 1
        refreshStarted?.resume()
        refreshStarted = nil
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func waitForRefresh() async {
        if count > 0 { return }
        await withCheckedContinuation { refreshStarted = $0 }
    }

    func complete(with session: AuthSession) {
        waiter?.resume(returning: session)
        waiter = nil
    }

    func refreshCount() -> Int { count }
}
