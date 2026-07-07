import Foundation

nonisolated enum GoalObjective: String, Codable, CaseIterable, Identifiable, Sendable {
    case muscleGain = "muscle_gain"
    case strength
    case fatLoss = "fat_loss"
    case endurance
    case general

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .muscleGain: return String(localized: "goal_spec.objective.muscle_gain")
        case .strength: return String(localized: "goal_spec.objective.strength")
        case .fatLoss: return String(localized: "goal_spec.objective.fat_loss")
        case .endurance: return String(localized: "goal_spec.objective.endurance")
        case .general: return String(localized: "goal_spec.objective.general")
        }
    }
}

nonisolated enum ExperienceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case beginner
    case intermediate
    case advanced

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .beginner: return String(localized: "goal_spec.experience.beginner")
        case .intermediate: return String(localized: "goal_spec.experience.intermediate")
        case .advanced: return String(localized: "goal_spec.experience.advanced")
        }
    }
}

/// Structured training goal — the input Phase 2's generation pipeline reads
/// instead of parsing free text. One per user; `note` keeps room for
/// unstructured detail the picker fields don't capture (see ADR-001 Phase 1).
nonisolated struct GoalSpec: Codable, Equatable, Sendable {
    var objective: GoalObjective
    var daysPerWeek: Int
    var sessionMinutes: Int
    var equipment: [Equipment]
    var focusAreas: [MuscleGroup]
    var experience: ExperienceLevel
    var note: String?

    static let `default` = GoalSpec(
        objective: .general,
        daysPerWeek: 3,
        sessionMinutes: 60,
        equipment: [],
        focusAreas: [],
        experience: .beginner,
        note: nil
    )

    /// Client-side range check. The server's CHECK constraints on
    /// `user_goal_specs` are a loose superset of these bounds — tightening
    /// them beyond what the client enforces can permanently poison a user's
    /// push (see the Phase 0 postmortem referenced in the migration comment).
    var isValid: Bool {
        (1...7).contains(daysPerWeek) && (15...240).contains(sessionMinutes)
    }
}
