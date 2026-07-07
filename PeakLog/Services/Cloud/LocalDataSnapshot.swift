import Foundation

/// The full user dataset, snapshotted out of `LocalAppDatabase` for a cloud
/// push and assembled back in by a pull (`replaceAll`). Lives in its own file
/// so the pure `CloudMapper` translation can be unit-tested without the actor.
nonisolated struct LocalDataSnapshot: Sendable {
    let profile: UserProfile
    let activePlan: TrainingPlan
    let strengthSessions: [WorkoutSession]
    let runningRecords: [RunningWorkoutRecord]
    let customExercises: [ExerciseDefinition]
}
