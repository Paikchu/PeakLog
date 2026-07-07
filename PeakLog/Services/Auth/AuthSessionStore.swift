import Foundation
import Security

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

    func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }

        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var insert = baseQuery()
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func clear() {
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
