import Foundation

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
