import Foundation

nonisolated enum RunningWorkoutSource: String, Codable, Equatable, Sendable {
    case agent
    case manual

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "agent", "chat":
            self = .agent
        case "manual":
            self = .manual
        default:
            self = .manual
        }
    }
}

nonisolated struct RunningWorkoutRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let userId: String
    var workoutDate: Date
    var durationMinutes: Int
    var distanceKm: Double
    var source: RunningWorkoutSource
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct StrengthSessionDraft: Equatable, Sendable {
    nonisolated struct ExerciseDraft: Equatable, Sendable {
        nonisolated struct SetDraft: Equatable, Sendable {
            var weight: Double?
            var weightUnit: WeightUnit
            var reps: Int
            var rpe: Double?
        }

        var name: String
        var exerciseId: String? = nil
        var exerciseLoadType: ExerciseLoadType = .unknown
        var sets: [SetDraft]
    }

    var title: String?
    var workoutDate: Date
    var exercises: [ExerciseDraft]
}

// MARK: - Weight Unit
nonisolated enum WeightUnit: String, Codable, CaseIterable, Sendable {
    case kg
    case lbs

    var display: String { rawValue }
}

// MARK: - Exercise Set
nonisolated struct ExerciseSet: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var setIndex: Int        // 1-based display index
    var weight: Double?
    var weightUnit: WeightUnit
    var reps: Int
    var rpe: Double?
}

// MARK: - Exercise
nonisolated struct Exercise: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    /// Stable library slug; nil for legacy free-text entries.
    var exerciseId: String?
    /// Optional so pre-existing persisted sessions (recorded before this field
    /// existed) decode as nil rather than failing; nil is treated as unknown.
    var exerciseLoadType: ExerciseLoadType?
    var sets: [ExerciseSet]

    init(id: String, name: String, exerciseId: String? = nil, exerciseLoadType: ExerciseLoadType? = nil, sets: [ExerciseSet]) {
        self.id = id
        self.name = name
        self.exerciseId = exerciseId
        self.exerciseLoadType = exerciseLoadType
        self.sets = sets
    }
}

// MARK: - Workout Session
nonisolated struct WorkoutSession: Identifiable, Codable, Sendable {
    let id: String
    let userId: String
    var date: Date
    var durationMinutes: Int?
    var label: String?             // e.g. "Pull Day"
    var exercises: [Exercise]
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct WorkoutRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var exercises: [Exercise]
}

// MARK: - Session Summary (used in HistoryScreen list)
nonisolated struct SessionSummary: Identifiable, Codable, Sendable {
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

enum CalendarDayTextColorRole: Equatable {
    case selected
    case primary
    case muted
}

extension CalendarDay {
    var isInteractable: Bool {
        true
    }

    var showsSelectionHighlight: Bool {
        isSelected
    }

    var showsTodayOutline: Bool {
        isToday && !isSelected
    }

    var showsWorkoutIndicator: Bool {
        hasWorkout
    }

    var textColorRole: CalendarDayTextColorRole {
        if isSelected { return .selected }
        if !isCurrentMonth { return .muted }
        return .primary
    }
}
