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

    /// Caught in review: `save`'s delete-then-add is not atomic, so a `load`
    /// that happens to run during that window must still never observe
    /// "session missing" — it must block on the shared lock until `save`
    /// finishes, not race in and read a transient "not found".
    ///
    /// This forces the interleaving deterministically instead of hoping a
    /// stress test happens to land in a microseconds-wide window: a DEBUG-
    /// only hook (`test_onDeleteBeforeAdd`) pauses `save` *after*
    /// `SecItemDelete` and *before* `SecItemAdd`, while it still holds the
    /// lock. We only start the concurrent `load` once we know `save` is
    /// paused there, then release `save` after giving `load` time to have
    /// actually called `lock()` and blocked. If `load` didn't take the lock,
    /// it would return nil immediately; with the fix it can only return
    /// once `save` has completed the add and released the lock.
    func testConcurrentLoadDuringSaveNeverObservesMissingSession() throws {
        let store = KeychainAuthSessionStore(service: uniqueService())
        defer {
            KeychainAuthSessionStore.test_onDeleteBeforeAdd = nil
            store.clear()
        }

        let seed = session(accessToken: "seed", refreshToken: "refresh-seed")
        store.save(seed)
        XCTAssertEqual(store.load(), seed)

        let saveReachedWindow = XCTestExpectation(description: "save is paused between delete and add")
        let releaseAdd = DispatchSemaphore(value: 0)

        KeychainAuthSessionStore.test_onDeleteBeforeAdd = {
            saveReachedWindow.fulfill()
            releaseAdd.wait()
        }

        let updated = session(accessToken: "updated", refreshToken: "refresh-updated")
        DispatchQueue.global().async {
            store.save(updated)
        }

        wait(for: [saveReachedWindow], timeout: 2)

        var loadedSession: AuthSession?
        let loadCompleted = XCTestExpectation(description: "load completed")
        DispatchQueue.global().async {
            loadedSession = store.load()
            loadCompleted.fulfill()
        }

        // Give the concurrent load() time to actually enter `load()` and
        // block on the (still-held) lock before we let save() proceed.
        Thread.sleep(forTimeInterval: 0.2)
        releaseAdd.signal()

        wait(for: [loadCompleted], timeout: 2)

        XCTAssertNotNil(loadedSession, "load() must never observe a missing session while a save() is mid-flight")
        if let loadedSession {
            XCTAssertTrue(
                loadedSession == seed || loadedSession == updated,
                "load() must observe either the pre-save or post-save session, never a transient gap"
            )
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
