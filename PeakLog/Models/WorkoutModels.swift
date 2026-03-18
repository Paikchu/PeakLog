import Foundation

// MARK: - Weight Unit
enum WeightUnit: String, Codable, CaseIterable {
    case kg
    case lbs

    var display: String { rawValue }
}

// MARK: - Exercise Set
struct ExerciseSet: Identifiable, Codable, Equatable {
    let id: String
    var setIndex: Int        // 1-based display index
    var weight: Double
    var weightUnit: WeightUnit
    var reps: Int
}

// MARK: - Exercise
struct Exercise: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var sets: [ExerciseSet]
}

// MARK: - Workout Session
struct WorkoutSession: Identifiable, Codable {
    let id: String
    let userId: String
    var date: Date
    var durationMinutes: Int?
    var label: String?             // e.g. "Pull Day"
    var exercises: [Exercise]
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - Session Summary (used in HistoryScreen list)
struct SessionSummary: Identifiable, Codable {
    let id: String
    let date: Date
    let label: String?
    let durationMinutes: Int?
    let exerciseCount: Int
    let totalSets: Int
}

// MARK: - Calendar Day (used in calendar grid)
struct CalendarDay: Identifiable {
    let id: String
    let date: Date
    let hasWorkout: Bool
    let isToday: Bool
    let isSelected: Bool
    let isCurrentMonth: Bool
}
