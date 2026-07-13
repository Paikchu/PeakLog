import XCTest
@testable import PeakLog

/// Exercises the real Keychain via `KeychainAuthSessionStore`. Each test uses
/// a unique `service` string so parallel test runs (and any other Keychain
/// data on the box) can't collide, and cleans up after itself.
final class KeychainAuthSessionStoreTests: XCTestCase {
    func testSaveIsUpsertAndSurvivesRepeatedWrites() throws {
        let store = KeychainAuthSessionStore(service: uniqueService())
        defer { store.clear() }

        let first = session(accessToken: "first", refreshToken: "refresh-1")
        store.save(first)
        XCTAssertEqual(store.load(), first)

        // A second save to the same (service, account) must update in place,
        // not silently no-op or duplicate.
        let second = session(accessToken: "second", refreshToken: "refresh-2")
        store.save(second)
        XCTAssertEqual(store.load(), second)
    }

    func testClearRemovesTheSession() throws {
        let store = KeychainAuthSessionStore(service: uniqueService())
        store.save(session(accessToken: "token", refreshToken: "refresh"))
        XCTAssertNotNil(store.load())

        store.clear()
        XCTAssertNil(store.load())
    }

    /// Issue #34: concurrent saves to the same store must not race into a
    /// dropped/duplicated write. Every writer's session is a valid outcome
    /// (they're all racing for the same slot), but the store must end up
    /// holding exactly one of them, not nil and not silently unwritten.
    func testConcurrentSavesDoNotDropTheSession() async throws {
        let store = KeychainAuthSessionStore(service: uniqueService())
        defer { store.clear() }

        let sessions = (0..<8).map { session(accessToken: "token-\($0)", refreshToken: "refresh-\($0)") }

        await withTaskGroup(of: Void.self) { group in
            for candidate in sessions {
                group.addTask {
                    store.save(candidate)
                }
            }
        }

        let loaded = store.load()
        XCTAssertNotNil(loaded, "A concurrent save must not leave the Keychain entry missing")
        if let loaded {
            XCTAssertTrue(sessions.contains(loaded), "The persisted session must be one of the racing writers")
        }
    }

    private func uniqueService() -> String {
        "com.max.PeakLog.auth.test.\(UUID().uuidString)"
    }

    private func session(accessToken: String, refreshToken: String) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: 20_000),
            user: AuthedUser(id: "user-1", email: "user@example.com")
        )
    }
}
