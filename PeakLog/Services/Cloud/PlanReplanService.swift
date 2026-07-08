import Foundation

/// Calls the `generate-weekly-plan` Edge Function in `mode: "replan"` on the
/// user's behalf (Phase 3). Unlike the PostgREST sync path, this hits a
/// Function endpoint and authenticates with the user's own JWT — the server
/// verifies the token's uid matches `user_id` before touching anything.
///
/// This is the ONLY place the client ever triggers server-side generation; it
/// is scoped to replan (the weekly path stays backend-only). The service does
/// no local mutation and does not pull — the caller records the local signal
/// event and refreshes after a successful call.
nonisolated struct PlanReplanService: Sendable {
    /// A structured outcome so the UI can show an honest, specific toast
    /// instead of a generic success/failure.
    enum Outcome: Sendable, Equatable {
        case replanned([String])          // replannedDates
        case noChange(reason: String)     // no_op / skipped / rate_limited — plan unchanged, not an error
        case failed(reason: String)       // the plan is intentionally left untouched on failure (C24)
    }

    private let config: SupabaseConfig
    private let tokenProvider: TokenProviding
    private let session: URLSession

    init(config: SupabaseConfig = .current, tokenProvider: TokenProviding, session: URLSession = .shared) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func requestReplan(userId: String, signal: ReplanSignal) async throws -> Outcome {
        let url = config.url
            .appendingPathComponent("functions/v1")
            .appendingPathComponent("generate-weekly-plan")

        let token: String
        do {
            token = try await tokenProvider.validToken()
        } catch {
            throw CloudError.unauthorized
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            mode: "replan", user_id: userId, signal: signal.rawValue
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudError.network
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.network }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw CloudError.unauthorized }
            throw CloudError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        guard let result = decoded.results.first else {
            return .noChange(reason: "no result")
        }
        switch result.status {
        case "replanned":
            return .replanned(result.replannedDates ?? [])
        case "no_op", "skipped", "rate_limited":
            return .noChange(reason: result.reason ?? result.status)
        default: // "failed", "error", or anything unexpected
            return .failed(reason: result.error ?? result.reason ?? result.status)
        }
    }

    private struct RequestBody: Encodable {
        let mode: String
        let user_id: String
        let signal: String
    }

    private struct ResponseEnvelope: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let status: String
        let replannedDates: [String]?
        let reason: String?
        let error: String?
    }
}
