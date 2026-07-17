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
    let goalSpec: GoalSpec?
    /// Not-yet-pushed edit events, for the push direction only. A snapshot
    /// assembled from a *pull* leaves this empty — pulled data represents
    /// cloud truth, not local outbox facts.
    let pendingEditEvents: [PlanEditEvent]
    /// `LocalAppDatabase`'s mutation counter at snapshot time. A successful
    /// push hands it back to `acknowledgePushedState` so the persisted
    /// "owes a push" flag is only cleared when nothing mutated mid-push.
    /// Snapshots assembled from a pull leave the default.
    var mutationSeq: Int64 = 0
}
