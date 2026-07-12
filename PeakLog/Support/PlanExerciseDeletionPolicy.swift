import Foundation

enum PlanExerciseDeletionPolicy {
    static func completedSetCount(for exercise: TrainingPlanExercise) -> Int {
        exercise.sets.filter(\.isCompleted).count
    }

    static func requiresConfirmation(for exercise: TrainingPlanExercise) -> Bool {
        completedSetCount(for: exercise) > 0
    }
}
