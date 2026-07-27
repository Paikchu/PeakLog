import XCTest
@testable import PeakLog

final class AuthStateManagerTests: XCTestCase {
    func testRestoreUsesProviderSession() async {
        let provider = TestAuthProvider(restoredUser: .fixture)
        let manager = await AuthStateManager(provider: provider)

        await manager.restore()

        let state = await manager.state
        XCTAssertEqual(state, .signedIn(.fixture))
    }

    func testRestoreWithoutProviderSessionSignsOut() async {
        let provider = TestAuthProvider(restoredUser: nil)
        let manager = await AuthStateManager(provider: provider)

        await manager.restore()

        let state = await manager.state
        XCTAssertEqual(state, .signedOut)
    }

    func testSignedOutEventClosesTheAuthGate() async {
        let provider = TestAuthProvider(restoredUser: .fixture)
        let manager = await AuthStateManager(provider: provider)
        await manager.restore()

        provider.emit(.signedOut)

        await waitUntil { await manager.state == .signedOut }
        let state = await manager.state
        XCTAssertEqual(state, .signedOut)
    }

    func testValidTokenNetworkFailureKeepsSignedInState() async {
        let provider = TestAuthProvider(restoredUser: .fixture, tokenError: .network)
        let manager = await AuthStateManager(provider: provider)
        await manager.restore()

        do {
            _ = try await manager.validToken()
            XCTFail("Expected the network failure")
        } catch AppAuthError.network {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await manager.state
        XCTAssertEqual(state, .signedIn(.fixture))
    }

    func testValidTokenRejectedRefreshSignsOut() async {
        let provider = TestAuthProvider(restoredUser: .fixture, tokenError: .invalidCredentials)
        let manager = await AuthStateManager(provider: provider)
        await manager.restore()

        do {
            _ = try await manager.validToken()
            XCTFail("Expected invalid credentials")
        } catch AppAuthError.invalidCredentials {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await manager.state
        XCTAssertEqual(state, .signedOut)
    }

    func testSignInGuardsAgainstDoubleSubmission() async {
        let gate = SignInGate()
        let provider = TestAuthProvider(
            restoredUser: nil,
            signIn: { _, _ in try await gate.signIn() }
        )
        let manager = await AuthStateManager(provider: provider)

        async let first: Void = manager.signIn(email: "user@example.com", password: "password")
        await gate.waitForSignIn()
        async let second: Void = manager.signIn(email: "user@example.com", password: "password")
        await Task.yield()

        let callsBeforeCompletion = await gate.callCount()
        XCTAssertEqual(callsBeforeCompletion, 1)
        await gate.complete(with: .fixture)
        _ = await (first, second)

        let callsAfterCompletion = await gate.callCount()
        let state = await manager.state
        XCTAssertEqual(callsAfterCompletion, 1)
        XCTAssertEqual(state, .signedIn(.fixture))
    }

    func testSignOutAlwaysClosesTheLocalGate() async {
        let provider = TestAuthProvider(restoredUser: .fixture)
        let manager = await AuthStateManager(provider: provider)
        await manager.restore()

        await manager.signOut()

        XCTAssertEqual(provider.signOutCallCount, 1)
        let state = await manager.state
        XCTAssertEqual(state, .signedOut)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
    }
}

private extension AuthedUser {
    static let fixture = AuthedUser(id: "user-1", email: "user@example.com")
}

private final class TestAuthProvider: AuthProviding, @unchecked Sendable {
    private let restoredUser: AuthedUser?
    private let tokenError: AppAuthError?
    private let signInHandler: @Sendable (String, String) async throws -> AuthedUser
    private let stream: AsyncStream<AuthProviderEvent>
    private let continuation: AsyncStream<AuthProviderEvent>.Continuation
    private let lock = NSLock()
    private var _signOutCallCount = 0

    init(
        restoredUser: AuthedUser?,
        tokenError: AppAuthError? = nil,
        signIn: @escaping @Sendable (String, String) async throws -> AuthedUser = { _, _ in .fixture }
    ) {
        self.restoredUser = restoredUser
        self.tokenError = tokenError
        self.signInHandler = signIn
        (stream, continuation) = AsyncStream.makeStream()
    }

    var signOutCallCount: Int {
        lock.withLock { _signOutCallCount }
    }

    func restoreUser() async -> AuthedUser? {
        restoredUser
    }

    func stateChanges() -> AsyncStream<AuthProviderEvent> {
        stream
    }

    func signIn(email: String, password: String) async throws -> AuthedUser {
        try await signInHandler(email, password)
    }

    func signOut() async {
        lock.withLock {
            _signOutCallCount += 1
        }
    }

    func validToken() async throws -> String {
        if let tokenError { throw tokenError }
        return "token"
    }

    func emit(_ event: AuthProviderEvent) {
        continuation.yield(event)
    }
}

private actor SignInGate {
    private var count = 0
    private var waiter: CheckedContinuation<AuthedUser, Error>?
    private var signInStarted: CheckedContinuation<Void, Never>?

    func signIn() async throws -> AuthedUser {
        count += 1
        signInStarted?.resume()
        signInStarted = nil
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func waitForSignIn() async {
        if count > 0 { return }
        await withCheckedContinuation { signInStarted = $0 }
    }

    func complete(with user: AuthedUser) {
        waiter?.resume(returning: user)
        waiter = nil
    }

    func callCount() -> Int {
        count
    }
}
