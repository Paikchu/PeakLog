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

    /// Merge cloud truth into the cache, then arm push-on-change. The merge
    /// (not a blind overwrite) preserves real offline user records —
    /// sessions, runs, custom exercises, and offline plan-set completions —
    /// while still dropping seed rows (non-UUID ids) so a later push can
    /// never send non-cloud rows. See `LocalAppDatabase.mergeFromCloud`
    /// (Issue #1 fix).
    func start() async {
        await database.prepareForCloudUser(userId)
        await pull()
        await installChangeHook()
    }

    func stop() async {
        await database.disarmCloudSync(userId: userId)
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
            // Merge (not replace) so offline user records survive the login
            // pull while seed rows are still dropped. See Issue #1 /
            // `LocalAppDatabase.mergeFromCloud`.
            await database.mergeFromCloud(
                profile: snapshot.profile,
                activePlan: snapshot.activePlan,
                strengthSessions: snapshot.strengthSessions,
                runningRecords: snapshot.runningRecords,
                customExercises: snapshot.customExercises,
                goalSpec: snapshot.goalSpec
            )
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = "pull: \(error)"
        }
    }

    // MARK: - Push

    private func installChangeHook() async {
        await database.armCloudSync(userId: userId) { [weak self] in
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
        var snapshot = await database.snapshot()

        // Revision guard (Phase 3): if the server's copy of the active plan
        // advanced since our last pull — a server-side replan landed while we
        // were holding unpushed local changes — we MUST pull-merge before
        // pushing. Otherwise the child-table `deleteNotIn` below would delete
        // the freshly replanned rows and re-upsert our stale ones, silently
        // undoing the replan the user just saw. Pulling first folds the replan
        // into the local cache (offline completions preserved, per Issue #1),
        // and re-snapshotting picks it up so the push echoes it back intact.
        // See Phase 3 plan §4.2/§4.3.
        if try await serverPlanRevisionAdvanced(beyond: snapshot.activePlan) {
            await pull()
            snapshot = await database.snapshot()
        }

        let bundle = try CloudMapper.pushBundle(from: snapshot, userId: userId)

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

        // user_goal_specs' PK IS user_id (unlike the two tables above), so an
        // upsert's conflict key is the PK directly — safe. Skipped entirely
        // if the user has never saved a goal (G5), rather than pushing a
        // synthetic default row.
        if let goalSpec = bundle.goalSpec {
            try await client.upsert(table: "user_goal_specs", rows: [goalSpec])
        }

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

        // Append-only: insert, skipping rows the cloud already has (a retried
        // push resending the same client-generated ids), never pruned or
        // overwritten (RLS grants plan_edit_events no UPDATE policy). Cleared
        // locally only once the cloud confirms receipt.
        if !bundle.editEvents.isEmpty {
            try await client.insertIgnoringDuplicates(table: "plan_edit_events", rows: bundle.editEvents)
            await database.clearPushedEditEvents(ids: Set(bundle.editEvents.map(\.id)))
        }

        // Prune rows the cloud has but the local cache no longer does. Children
        // first so a parent delete never strands a child mid-request.
        //
        // training_plans is intentionally NEVER pruned (SY1): the local cache
        // only ever holds the current week, so pruning by "not present
        // locally" would delete every past week's plan on the push right
        // after each rotation — destroying the history Phase 2's learning
        // loop depends on. The three child tables ARE pruned, but scoped to
        // the *active* plan only, so an archived week's rows are left alone
        // (SY2) — see also the matching scoped fetch in `CloudSnapshotLoader`.
        let activePlanScope = [URLQueryItem(name: "plan_id", value: "eq.\(snapshot.activePlan.id)")]
        try await client.deleteNotIn(table: "training_plan_sets", keepIds: bundle.planSets.map(\.id), extraFilters: activePlanScope)
        try await client.deleteNotIn(table: "training_plan_exercises", keepIds: bundle.planExercises.map(\.id), extraFilters: activePlanScope)
        try await client.deleteNotIn(table: "training_plan_days", keepIds: bundle.planDays.map(\.id), extraFilters: activePlanScope)
        try await client.deleteNotIn(table: "exercise_sets", keepIds: bundle.exerciseSets.map(\.id))
        try await client.deleteNotIn(table: "exercises", keepIds: bundle.exercises.map(\.id))
        try await client.deleteNotIn(table: "workout_sessions", keepIds: bundle.sessions.map(\.id))
        try await client.deleteNotIn(table: "running_workouts", keepIds: bundle.running.map(\.id))
        try await client.deleteNotIn(table: "custom_exercises", keepIds: bundle.customExercises.map(\.id))
    }

    /// Lightweight check: has the server's active-plan `revision` moved past the
    /// local baseline? A single-column, single-row fetch — cheap enough to run
    /// before every push. Returns false (no guard action) when the local plan
    /// has no cloud counterpart yet (a freshly seeded/empty plan whose id was
    /// generated locally), so a brand-new user's first push isn't blocked.
    private func serverPlanRevisionAdvanced(beyond localPlan: TrainingPlan) async throws -> Bool {
        let rows = try await client.fetch(TrainingPlanRevisionRow.self, table: "training_plans", query: [
            URLQueryItem(name: "id", value: "eq.\(localPlan.id)"),
            URLQueryItem(name: "select", value: "revision"),
            URLQueryItem(name: "limit", value: "1")
        ])
        guard let serverRevision = rows.first?.revision else { return false }
        return serverRevision != localPlan.revision
    }
}

/// Minimal projection for the revision guard's single-column probe.
private struct TrainingPlanRevisionRow: Decodable, Sendable {
    let revision: Int
}
