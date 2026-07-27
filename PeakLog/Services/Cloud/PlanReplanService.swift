import Foundation
import Supabase

nonisolated struct PlanReplanService: Sendable {
    enum Outcome: Sendable, Equatable {
        case replanned([String])
        case noChange(reason: String)
        case failed(reason: String)
    }

    private let apiClient: SupabaseAPIClient
    private let tokenProvider: TokenProviding

    init(client: SupabaseAPIClient, tokenProvider: TokenProviding) {
        self.apiClient = client
        self.tokenProvider = tokenProvider
    }

    func requestReplan(userId: String, signal: ReplanSignal) async throws -> Outcome {
        do {
            try await apiClient.authorize(using: tokenProvider)
        } catch {
            throw CloudError.unauthorized
        }

        let decoded: ResponseEnvelope
        do {
            decoded = try await apiClient.client.functions.invoke(
                "generate-weekly-plan",
                options: FunctionInvokeOptions(
                    body: RequestBody(
                        mode: "replan",
                        user_id: userId,
                        signal: signal.rawValue
                    )
                )
            )
        } catch {
            throw CloudErrorMapper.function(error)
        }

        guard let result = decoded.results.first else {
            return .noChange(reason: "no result")
        }
        switch result.status {
        case "replanned":
            return .replanned(result.replannedDates ?? [])
        case "no_op", "skipped", "rate_limited":
            return .noChange(reason: result.reason ?? result.status)
        default:
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
