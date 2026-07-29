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
    /// Records the user deleted that the cloud has not confirmed dropping yet.
    /// The push deletes exactly these ids — it never infers a deletion from a
    /// row's absence, because absence also describes rows another device added
    /// and this one has not seen (Issue #132). Empty on a snapshot assembled
    /// from a pull: cloud rows carry no local deletion intent.
    var pendingRecordDeletions: RecordDeletionLog = RecordDeletionLog()
}
