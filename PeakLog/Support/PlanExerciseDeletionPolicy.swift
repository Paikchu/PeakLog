import Foundation

/// `nonisolated`: pure predicates over a plan exercise; the module default
/// `@MainActor` would only make them unusable off the main actor (issue #137).
nonisolated enum PlanExerciseDeletionPolicy {
    static func completedSetCount(for exercise: TrainingPlanExercise) -> Int {
        exercise.sets.filter(\.isCompleted).count
    }

    static func requiresConfirmation(for exercise: TrainingPlanExercise) -> Bool {
        completedSetCount(for: exercise) > 0
    }
}
