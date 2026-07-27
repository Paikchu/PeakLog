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

    func makeAPIClient() -> SupabaseAPIClient {
        let tokenRelay = ValidatedAccessTokenRelay()
        let client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(
                    autoRefreshToken: false,
                    accessToken: {
                        await tokenRelay.accessTokenForSDK()
                    }
                ),
                global: .init(session: apiSession)
            )
        )
        return SupabaseAPIClient(client: client, tokenRelay: tokenRelay)
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
    let client: SupabaseClient
    private let tokenRelay: ValidatedAccessTokenRelay

    fileprivate init(client: SupabaseClient, tokenRelay: ValidatedAccessTokenRelay) {
        self.client = client
        self.tokenRelay = tokenRelay
    }

    func authorize(using tokenProvider: TokenProviding) async throws {
        do {
            let token = try await tokenProvider.validToken()
            guard !token.isEmpty else { throw AppAuthError.invalidCredentials }
            await tokenRelay.setValidatedToken(token)
        } catch {
            await tokenRelay.clear()
            throw error
        }
    }
}

private actor ValidatedAccessTokenRelay {
    private var token: String?

    func setValidatedToken(_ token: String) {
        self.token = token
    }

    func clear() {
        token = nil
    }

    func accessTokenForSDK() -> String {
        token ?? "peaklog-missing-valid-token"
    }
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
