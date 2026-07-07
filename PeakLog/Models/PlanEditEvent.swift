import Foundation

nonisolated enum PlanEditEventType: String, Codable, Sendable {
    case exerciseAdded = "exercise_added"
    case exerciseRemoved = "exercise_removed"
    case setAdded = "set_added"
    case setRemoved = "set_removed"
    case setTargetUpdated = "set_target_updated"
    case exercisesReordered = "exercises_reordered"
    case goalChanged = "goal_changed"
}

nonisolated enum PlanEditEventSource: String, Codable, Sendable {
    case user
    case agent
    case system
}

/// A structural edit to the training plan, recorded at `LocalAppDatabase`'s
/// single mutation choke point (see ADR-001 Phase 1 / the phase1 plan §4.2).
/// Append-only fact, not app state: never mutated or deleted once created,
/// and deliberately excluded from the cloud sync's full-state reconcile (see
/// `CloudSyncCoordinator`) — it is only ever inserted, never pruned or pulled.
///
/// Completing a planned set is NOT recorded here: that outcome is already
/// fully captured by `TrainingPlanSet.completedAt` / `linkedExerciseSetId`,
/// which is what Phase 2's adherence-rate calculation reads instead. Mixing
/// "the user changed the plan's structure" with "the user did what the plan
/// already said" would blur the one signal this stream exists to isolate.
nonisolated struct PlanEditEvent: Codable, Equatable, Sendable {
    let id: String
    /// The account this event was recorded under. Lets a later sign-in under
    /// a different account on the same device discard leftover events that
    /// don't belong to it, instead of mis-attributing them (or having the
    /// push rejected by RLS) — see `LocalAppDatabase.armCloudSync`.
    let userId: String
    let planId: String?
    let planDayId: String?
    let planDate: String?
    let eventType: PlanEditEventType
    let exerciseName: String?
    let exerciseId: String?
    let payload: JSONValue
    let source: PlanEditEventSource
    /// Client-assigned monotonic counter, persisted alongside the event so a
    /// restart never reuses or rewinds it. Orders same-second events and
    /// survives clock skew/rollback, where `occurredAt` alone can't.
    let clientSeq: Int64
    let occurredAt: Date
}
