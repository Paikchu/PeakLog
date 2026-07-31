import Foundation
import Supabase

nonisolated struct SupabaseClientFactory: Sendable {
    static let authStorageService = "com.max.PeakLog.auth"
    static let authStorageKey = "current-session"

    private let config: SupabaseConfig
    private let authStorage: any AuthLocalStorage
    private let authSession: URLSession
    private let apiSession: URLSession

    /// No default for `config`: `SupabaseConfig.current` is optional now, and
    /// deciding what to do when it is nil belongs to the caller (see
    /// `UnconfiguredAuthProvider`), not to a silently substituted default.
    init(
        config: SupabaseConfig,
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

    func makeAuthProvider() -> SupabaseAuthProvider {
        let storage = authStorage
        return SupabaseAuthProvider(
            client: makeAuthClient(),
            clearPersistedSession: {
                try storage.remove(key: Self.authStorageKey)
            }
        )
    }

    func makeAPIClient() -> SupabaseAPIClient {
        let client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(
                    autoRefreshToken: false,
                    accessToken: {
                        SupabaseAPIRequestContext.accessToken
                            ?? "peaklog-missing-valid-token"
                    }
                ),
                global: .init(session: apiSession)
            )
        )
        return SupabaseAPIClient(client: client)
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

nonisolated struct SupabaseAPIClient: Sendable {
    private let client: SupabaseClient

    fileprivate init(client: SupabaseClient) {
        self.client = client
    }

    func withAuthorization<Result>(
        using tokenProvider: TokenProviding,
        operation: (SupabaseClient) async throws -> Result
    ) async throws -> Result {
        let token: String
        do {
            token = try await tokenProvider.validToken()
            guard !token.isEmpty else { throw AppAuthError.invalidCredentials }
        } catch {
            throw SupabaseAPIAuthorizationError.unauthorized
        }

        return try await SupabaseAPIRequestContext.$accessToken.withValue(token) {
            try await operation(client)
        }
    }
}

nonisolated enum SupabaseAPIAuthorizationError: Error, Sendable {
    case unauthorized
}

private nonisolated enum SupabaseAPIRequestContext {
    @TaskLocal static var accessToken: String?
}

nonisolated struct ValidatingAuthLocalStorage: AuthLocalStorage {
    private let storage: any AuthLocalStorage
    private let sessionKey: String

    init(
        storage: any AuthLocalStorage,
        sessionKey: String = SupabaseClientFactory.authStorageKey
    ) {
        self.storage = storage
        self.sessionKey = sessionKey
    }

    func store(key: String, value: Data) throws {
        try storage.store(key: key, value: value)
    }

    func retrieve(key: String) throws -> Data? {
        guard let data = try storage.retrieve(key: key) else { return nil }
        guard key == sessionKey else { return data }
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
