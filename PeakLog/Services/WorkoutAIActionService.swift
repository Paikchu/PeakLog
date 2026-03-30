import Foundation
import Supabase

struct AIWorkoutQuickAction: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let prompt: String
}

struct AIWorkoutExerciseInsight: Decodable, Equatable {
    let exerciseName: String
    let previousPerformanceSummary: String?
    let suggestion: String?

    enum CodingKeys: String, CodingKey {
        case exerciseName = "exerciseName"
        case previousPerformanceSummary = "previousPerformanceSummary"
        case suggestion
    }
}

struct WorkoutAIActionResponse: Decodable {
    let status: String
    let reply: String
    let requiresTodayRefresh: Bool
    let quickActions: [AIWorkoutQuickAction]
    let exerciseInsights: [AIWorkoutExerciseInsight]

    enum CodingKeys: String, CodingKey {
        case status
        case reply
        case requiresTodayRefresh = "requiresTodayRefresh"
        case quickActions = "quickActions"
        case exerciseInsights = "exerciseInsights"
    }
}

protocol WorkoutAIActionServiceProtocol {
    func submitAction(text: String, targetDate: String?) async throws -> WorkoutAIActionResponse
}

final class SupabaseWorkoutAIActionService: WorkoutAIActionServiceProtocol {
    private let supabase = SupabaseManager.shared.client
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func submitAction(text: String, targetDate: String?) async throws -> WorkoutAIActionResponse {
        let authSession = try await supabase.auth.session
        let url = SupabaseConfig.url
            .appending(path: "functions")
            .appending(path: "v1")
            .appending(path: "ai-workout-action")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")

        let body = [
            "text": text,
            "targetDate": targetDate,
        ] as [String: Any?]

        request.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        default:
            if
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = object["error"] as? String,
                !message.isEmpty
            {
                throw NSError(domain: "PeakLog.WorkoutAIActionService", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: message,
                ])
            }
            throw APIError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(WorkoutAIActionResponse.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }
}

final class MockWorkoutAIActionService: WorkoutAIActionServiceProtocol {
    func submitAction(text: String, targetDate: String?) async throws -> WorkoutAIActionResponse {
        _ = targetDate
        return WorkoutAIActionResponse(
            status: "completed",
            reply: "已处理：\(text)",
            requiresTodayRefresh: true,
            quickActions: [],
            exerciseInsights: []
        )
    }
}
