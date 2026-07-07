import Foundation

/// Owns the read/write sync loop for a signed-in user.
///
/// Write model (a deliberate inversion of the plan's "cloud-first"): mutations
/// hit the local cache first — reusing all of `LocalAppDatabase`'s domain logic
/// — then a full-state reconcile pushes the result to the cloud (bulk upsert +
/// prune-not-present, per table). One uniform path covers every mutation
/// instead of bespoke cloud code per method, and a failed push self-heals on
/// the next pull. See docs/plans Phase 0 §1 / the step-4 log.
actor CloudSyncCoordinator {
    private let client: SupabaseDataClient
    private let loader: CloudSnapshotLoader
    private let database: LocalAppDatabase
    private let userId: String

    private var isPushing = false
    private var pushAgain = false
    private(set) var hasUnpushedChanges = false
    private(set) var lastErrorDescription: String?
    private let onStatusChange: (@Sendable (CloudSyncStatus) -> Void)?

    /// Latest sync error and whether a push is still owed — for diagnostics.
    func diagnostics() -> (error: String?, pending: Bool) {
        (lastErrorDescription, hasUnpushedChanges)
    }

    init(
        client: SupabaseDataClient,
        database: LocalAppDatabase,
        userId: String,
        onStatusChange: (@Sendable (CloudSyncStatus) -> Void)? = nil
    ) {
        self.client = client
        self.loader = CloudSnapshotLoader(client: client)
        self.database = database
        self.userId = userId
        self.onStatusChange = onStatusChange
    }

    // MARK: - Lifecycle

    /// Pull cloud truth into the cache, then arm push-on-change. Pulling first
    /// is essential: it overwrites any seed/stale cache so a later push can
    /// never send non-cloud (e.g. seed, non-UUID) rows.
    func start() async {
        await pull()
        await installChangeHook()
    }

    func stop() async {
        await database.setOnChange(nil)
    }

    /// On returning to the foreground: if we owe the cloud a push, retry it;
    /// otherwise pull to pick up anything changed on another device.
    func onForeground() async {
        if hasUnpushedChanges {
            await requestPush()
        } else {
            await pull()
        }
    }

    // MARK: - Pull

    func pull() async {
        do {
            let snapshot = try await loader.load(userId: userId)
            await database.replaceAll(
                profile: snapshot.profile,
                activePlan: snapshot.activePlan,
                strengthSessions: snapshot.strengthSessions,
                runningRecords: snapshot.runningRecords,
                customExercises: snapshot.customExercises
            )
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = "pull: \(error)"
        }
    }

    // MARK: - Push

    private func installChangeHook() async {
        await database.setOnChange { [weak self] in
            guard let self else { return }
            Task { await self.requestPush() }
        }
    }

    /// Coalesced, serialized full-state push. Concurrent mutations collapse into
    /// at most one in-flight push plus one queued re-run that captures the
    /// latest snapshot.
    func requestPush() async {
        hasUnpushedChanges = true
        if isPushing {
            pushAgain = true
            return
        }
        isPushing = true
        defer { isPushing = false }
        onStatusChange?(.syncing)

        repeat {
            pushAgain = false
            do {
                try await performPush()
                hasUnpushedChanges = false
                lastErrorDescription = nil
            } catch {
                // Leave hasUnpushedChanges set so onForeground retries later.
                let description = "\(error)"
                lastErrorDescription = "push: \(description)"
                onStatusChange?(.pendingRetry(description))
                return
            }
        } while pushAgain
        onStatusChange?(.idle)
    }

    private func performPush() async throws {
        let snapshot = await database.snapshot()
        let bundle = CloudMapper.pushBundle(from: snapshot, userId: userId)

        // profiles and user_preferences already exist (created by the
        // handle_new_user trigger) and can't be upserted — profiles has no
        // INSERT policy, user_preferences is unique on user_id, not the PK we
        // hold. Update them in place instead.
        try await client.update(
            table: "profiles",
            match: [URLQueryItem(name: "id", value: "eq.\(userId)")],
            row: bundle.profile
        )
        try await client.update(
            table: "user_preferences",
            match: [URLQueryItem(name: "user_id", value: "eq.\(userId)")],
            row: bundle.preferences
        )

        // Upsert parents before children so foreign keys always resolve;
        // exercise_sets precede plan sets because a plan set may link one.
        try await client.upsert(table: "custom_exercises", rows: bundle.customExercises)
        try await client.upsert(table: "workout_sessions", rows: bundle.sessions)
        try await client.upsert(table: "exercises", rows: bundle.exercises)
        try await client.upsert(table: "exercise_sets", rows: bundle.exerciseSets)
        try await client.upsert(table: "running_workouts", rows: bundle.running)
        try await client.upsert(table: "training_plans", rows: bundle.plans)
        try await client.upsert(table: "training_plan_days", rows: bundle.planDays)
        try await client.upsert(table: "training_plan_exercises", rows: bundle.planExercises)
        try await client.upsert(table: "training_plan_sets", rows: bundle.planSets)

        // Prune rows the cloud has but the local cache no longer does. Children
        // first so a parent delete never strands a child mid-request.
        try await client.deleteNotIn(table: "training_plan_sets", keepIds: bundle.planSets.map(\.id))
        try await client.deleteNotIn(table: "training_plan_exercises", keepIds: bundle.planExercises.map(\.id))
        try await client.deleteNotIn(table: "training_plan_days", keepIds: bundle.planDays.map(\.id))
        try await client.deleteNotIn(table: "training_plans", keepIds: bundle.plans.map(\.id))
        try await client.deleteNotIn(table: "exercise_sets", keepIds: bundle.exerciseSets.map(\.id))
        try await client.deleteNotIn(table: "exercises", keepIds: bundle.exercises.map(\.id))
        try await client.deleteNotIn(table: "workout_sessions", keepIds: bundle.sessions.map(\.id))
        try await client.deleteNotIn(table: "running_workouts", keepIds: bundle.running.map(\.id))
        try await client.deleteNotIn(table: "custom_exercises", keepIds: bundle.customExercises.map(\.id))
    }
}
