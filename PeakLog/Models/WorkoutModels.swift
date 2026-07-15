import Foundation

nonisolated enum CardioActivityType: String, Codable, CaseIterable, Equatable, Sendable {
    case running
    case cycling
    case elliptical
    case stairClimber = "stair_climber"

    var supportsDistance: Bool {
        self == .running || self == .cycling
    }

    var localizedTitle: String {
        String(localized: String.LocalizationValue("cardio.activity.\(rawValue)"))
    }
}

nonisolated enum CardioMetricsError: Error, Equatable, Sendable {
    case invalidDuration
    case invalidDistance
    case unsupportedDistance
    case invalidRPE
}

nonisolated struct CardioMetrics: Codable, Equatable, Sendable {
    let activityType: CardioActivityType
    let durationMinutes: Int
    let distanceKm: Double?
    let rpe: Double?

    init(
        activityType: CardioActivityType,
        durationMinutes: Int,
        distanceKm: Double?,
        rpe: Double? = nil
    ) throws {
        guard durationMinutes > 0 else { throw CardioMetricsError.invalidDuration }
        if let distanceKm {
            guard distanceKm > 0 else { throw CardioMetricsError.invalidDistance }
            guard activityType.supportsDistance else { throw CardioMetricsError.unsupportedDistance }
        }
        if let rpe, !(1...10).contains(rpe) {
            throw CardioMetricsError.invalidRPE
        }
        self.activityType = activityType
        self.durationMinutes = durationMinutes
        self.distanceKm = distanceKm
        self.rpe = rpe
    }
}

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

nonisolated struct CardioWorkoutRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let userId: String
    var workoutDate: Date
    var activityType: CardioActivityType
    var durationMinutes: Int
    var distanceKm: Double?
    var rpe: Double?
    var source: RunningWorkoutSource
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        userId: String,
        workoutDate: Date,
        activityType: CardioActivityType = .running,
        durationMinutes: Int,
        distanceKm: Double?,
        rpe: Double? = nil,
        source: RunningWorkoutSource,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.userId = userId
        self.workoutDate = workoutDate
        self.activityType = activityType
        self.durationMinutes = durationMinutes
        self.distanceKm = distanceKm
        self.rpe = rpe
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, userId, workoutDate, activityType, durationMinutes, distanceKm, rpe, source, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        workoutDate = try container.decode(Date.self, forKey: .workoutDate)
        let rawActivityType = try container.decodeIfPresent(String.self, forKey: .activityType)
        activityType = rawActivityType.flatMap(CardioActivityType.init(rawValue:)) ?? .running
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)
        distanceKm = try container.decodeIfPresent(Double.self, forKey: .distanceKm)
        rpe = try container.decodeIfPresent(Double.self, forKey: .rpe)
        source = try container.decode(RunningWorkoutSource.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

typealias RunningWorkoutRecord = CardioWorkoutRecord

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

    /// Multiplier to convert a value in this unit to kilograms (canonical storage unit).
    var toKilogramsFactor: Double {
        switch self {
        case .kg: return 1.0
        case .lbs: return 0.45359237
        }
    }
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
