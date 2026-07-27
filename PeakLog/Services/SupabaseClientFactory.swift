import Foundation
import Supabase

nonisolated struct SupabaseClientFactory: Sendable {
    static let authStorageService = "com.max.PeakLog.auth"
    static let authStorageKey = "current-session"

    private let config: SupabaseConfig
    private let authStorage: any AuthLocalStorage
    private let authSession: URLSession
    private let apiSession: URLSession

    init(
        config: SupabaseConfig = .current,
        authStorage: any AuthLocalStorage = ValidatingAuthLocalStorage(
            storage: KeychainLocalStorage(service: authStorageService)
        ),
        authSession: URLSession? = nil,
        apiSession: URLSession? = nil
    ) {
        self.config = config
        self.authStorage = authStorage
        self.authSession = authSession ?? Self.makeSession(timeout: 30)
        self.apiSession = apiSession ?? Self.makeSession(timeout: 60)
    }

    func makeAuthClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: authStorage,
                    storageKey: Self.authStorageKey,
                    autoRefreshToken: true,
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(session: authSession)
            )
        )
    }

    func makeAPIClient(
        accessToken: @escaping @Sendable () async throws -> String?
    ) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(
                    autoRefreshToken: false,
                    accessToken: accessToken
                ),
                global: .init(session: apiSession)
            )
        )
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        URLSession(configuration: sessionConfiguration(timeout: timeout))
    }

    static func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }
}

nonisolated struct ValidatingAuthLocalStorage: AuthLocalStorage {
    private let storage: any AuthLocalStorage

    init(storage: any AuthLocalStorage) {
        self.storage = storage
    }

    func store(key: String, value: Data) throws {
        try storage.store(key: key, value: value)
    }

    func retrieve(key: String) throws -> Data? {
        guard let data = try storage.retrieve(key: key) else { return nil }
        guard (try? JSONDecoder().decode(Session.self, from: data)) != nil else {
            try storage.remove(key: key)
            return nil
        }
        return data
    }

    func remove(key: String) throws {
        try storage.remove(key: key)
    }
}
