import Foundation

/// Talks to Supabase Auth (GoTrue) over plain HTTP. We call the REST endpoints
/// directly with `URLSession` rather than pulling in supabase-swift: it keeps
/// the app dependency-light and every request mockable via an injected session.
/// The publishable key rides in the `apikey` header; per-user authorization is
/// the returned JWT, enforced server-side by RLS.
nonisolated struct SupabaseAuthProvider: AuthProviding {
    private let config: SupabaseConfig
    private let session: URLSession

    init(config: SupabaseConfig = .current, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        try await tokenRequest(
            grantType: "password",
            body: ["email": email, "password": password]
        )
    }

    func refresh(refreshToken: String) async throws -> AuthSession {
        try await tokenRequest(
            grantType: "refresh_token",
            body: ["refresh_token": refreshToken]
        )
    }

    func signOut(accessToken: String) async {
        guard var components = URLComponents(
            url: config.url.appendingPathComponent("auth/v1/logout"),
            resolvingAgainstBaseURL: false
        ) else { return }
        components.queryItems = [URLQueryItem(name: "scope", value: "local")]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Revocation is best-effort; local teardown proceeds regardless.
        _ = try? await session.data(for: request)
    }

    // MARK: - Token endpoint

    private func tokenRequest(grantType: String, body: [String: String]) async throws -> AuthSession {
        guard var components = URLComponents(
            url: config.url.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        ) else { throw AuthError.notConfigured }
        components.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
        guard let url = components.url else { throw AuthError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network
        }

        guard let http = response as? HTTPURLResponse else { throw AuthError.network }

        switch http.statusCode {
        case 200...299:
            return try Self.decodeSession(from: data)
        case 400, 401, 403:
            // GoTrue returns these for bad passwords / revoked refresh tokens.
            throw AuthError.invalidCredentials
        default:
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw AuthError.server(message: message)
        }
    }

    // MARK: - Decoding

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int?
        let expiresAt: Int?
        let user: UserPayload

        struct UserPayload: Decodable {
            let id: String
            let email: String?
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case user
        }
    }

    static func decodeSession(from data: Data, now: Date = Date()) throws -> AuthSession {
        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.server(message: "Malformed auth response")
        }

        let expiry: Date
        if let at = token.expiresAt {
            expiry = Date(timeIntervalSince1970: TimeInterval(at))
        } else if let inSeconds = token.expiresIn {
            expiry = now.addingTimeInterval(TimeInterval(inSeconds))
        } else {
            expiry = now.addingTimeInterval(3600)
        }

        return AuthSession(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: expiry,
            user: AuthedUser(id: token.user.id, email: token.user.email)
        )
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["error_description"] as? String)
            ?? (object["msg"] as? String)
            ?? (object["message"] as? String)
            ?? (object["error"] as? String)
    }
}
