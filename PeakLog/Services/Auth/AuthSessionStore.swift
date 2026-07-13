import Foundation
import Security
import os

/// Where a signed-in session lives between launches. Tokens are credentials, so
/// they belong in the Keychain, not `UserDefaults`. The protocol lets tests and
/// previews swap in an in-memory store.
protocol AuthSessionStoring: Sendable {
    func load() -> AuthSession?
    func save(_ session: AuthSession)
    func clear()
}

/// Keychain-backed store. Persists a single JSON-encoded `AuthSession` under a
/// fixed account key; `save` is an upsert, `clear` removes it.
nonisolated struct KeychainAuthSessionStore: AuthSessionStoring {
    private let service: String
    private let account = "current-session"

    /// Serializes `save` across every instance that targets the Keychain (the
    /// service/account pair is effectively a single logical resource for this
    /// app). Delete-then-add is not atomic as far as the Keychain is
    /// concerned, so without this lock two concurrent `save` calls can both
    /// observe "not found" and both `SecItemAdd`, with the loser silently
    /// failing on `errSecDuplicateItem`.
    private static let lock = NSLock()

    private static let logger = Logger(subsystem: "com.max.PeakLog", category: "AuthSessionStore")

    init(service: String = "com.max.PeakLog.auth") {
        self.service = service
    }

    func load() -> AuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    /// Upsert via delete-then-add: simpler and more robust than update-else-
    /// insert, and — combined with `lock` — avoids the double-insert race
    /// where two concurrent saves both hit `errSecItemNotFound` and both
    /// `SecItemAdd`. Any unexpected `OSStatus` is logged rather than
    /// swallowed, so a save that silently drops the session is visible in
    /// device logs instead of just manifesting as "user got logged out".
    func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else {
            Self.logger.error("save: failed to encode AuthSession, nothing persisted")
            return
        }

        Self.lock.lock()
        defer { Self.lock.unlock() }

        let deleteStatus = SecItemDelete(baseQuery() as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            Self.logger.error("save: SecItemDelete failed with status \(deleteStatus, privacy: .public)")
            return
        }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.logger.error("save: SecItemAdd failed with status \(addStatus, privacy: .public)")
        }
    }

    func clear() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// In-memory store for previews and DEBUG local mode — never touches the Keychain.
final class InMemoryAuthSessionStore: AuthSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?

    init(seed: AuthSession? = nil) { self.session = seed }

    func load() -> AuthSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    func save(_ session: AuthSession) {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        session = nil
    }
}
