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

    private func session(accessToken: String, refreshToken: String, expiresAt: TimeInterval) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAt),
            user: AuthedUser(id: "user-1", email: "user@example.com")
        )
    }
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
