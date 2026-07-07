import Foundation

// MARK: - Date helpers

/// Cloud date/time columns are carried as strings in the DTOs so a single
/// `JSONDecoder` never has to juggle `date` and `timestamptz` at once. These
/// helpers convert at the mapping boundary instead.
nonisolated enum CloudDate {
    /// "yyyy-MM-dd" columns (workout_date, plan_date, week_start_date).
    static func day(from string: String) -> Date? {
        WorkoutDateFormatter().date(from: string)
    }

    static func dayString(from date: Date) -> String {
        WorkoutDateFormatter().string(from: date)
    }

    /// timestamptz columns. Postgres emits fractional seconds; tolerate both.
    static func timestamp(from string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - profiles / preferences

nonisolated struct ProfileRow: Codable, Sendable {
    let id: String
    var display_name: String
    var avatar_url: String?
    var membership_type: String
    var timezone: String
    var fitness_goal_summary: String?
}

nonisolated struct PreferencesRow: Codable, Sendable {
    let user_id: String
    var notifications_enabled: Bool
    var dark_mode_enabled: Bool
    var weight_unit: String
    var language: String
}

// MARK: - training plan aggregate

nonisolated struct TrainingPlanRow: Codable, Sendable {
    let id: String
    let user_id: String
    var week_start_date: String
    var status: String
    var goal_snapshot: String?
    var coach_summary: String
}

nonisolated struct TrainingPlanDayRow: Codable, Sendable {
    let id: String
    let plan_id: String
    let user_id: String
    var plan_date: String
    var day_index: Int
    var title: String
    var focus: String?
    var status: String
}

nonisolated struct TrainingPlanExerciseRow: Codable, Sendable {
    let id: String
    let plan_id: String
    let plan_day_id: String
    let user_id: String
    var order_index: Int
    var exercise_name: String
    var exercise_id: String?
    var progression_mode: String
    var exercise_load_type: String
    var notes: String?
}

nonisolated struct TrainingPlanSetRow: Codable, Sendable {
    let id: String
    let plan_id: String
    let plan_exercise_id: String
    let user_id: String
    var set_index: Int
    var target_weight: Double?
    var target_weight_unit: String
    var target_reps: Int
    var completed_at: String?
    var linked_exercise_set_id: String?
}

// MARK: - strength session aggregate

nonisolated struct WorkoutSessionRow: Codable, Sendable {
    let id: String
    let user_id: String
    var workout_date: String
    var title: String?
    var source_type: String
    var duration_seconds: Int?
    var created_at: String?
    var updated_at: String?
}

nonisolated struct ExerciseRow: Codable, Sendable {
    let id: String
    let session_id: String
    let user_id: String
    var name: String
    var normalized_name: String?
    var exercise_id: String?
    var exercise_load_type: String
    var order_index: Int
}

nonisolated struct ExerciseSetRow: Codable, Sendable {
    let id: String
    let exercise_id: String
    let user_id: String
    var set_index: Int
    var weight: Double?
    var weight_unit: String
    var reps: Int?
    var rpe: Double?
}

// MARK: - running / custom exercises

nonisolated struct RunningWorkoutRow: Codable, Sendable {
    let id: String
    let user_id: String
    var workout_date: String
    var duration_minutes: Int
    var distance_km: Double
    var source: String
    var created_at: String?
    var updated_at: String?
}

// MARK: - goal spec / plan edit events (Phase 1)

nonisolated struct GoalSpecRow: Codable, Sendable {
    let user_id: String
    var objective: String
    var days_per_week: Int
    var session_minutes: Int
    var equipment: [String]
    var focus_areas: [String]
    var experience: String
    var note: String?
}

nonisolated struct PlanEditEventRow: Codable, Sendable {
    let id: String
    let user_id: String
    var plan_id: String?
    var plan_day_id: String?
    var plan_date: String?
    var event_type: String
    var exercise_name: String?
    var exercise_id: String?
    var payload: JSONValue
    var source: String
    var client_seq: Int64
    var occurred_at: String
}

nonisolated struct CustomExerciseRow: Codable, Sendable {
    let id: String
    let user_id: String
    var name_en: String
    var name_zh: String
    var aliases: [String]
    var muscle_group: String
    var equipment: String
    var load_type: String
    var popularity: Int
}
