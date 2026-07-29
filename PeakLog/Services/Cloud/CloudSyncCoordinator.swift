import Foundation
import os

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
    /// True once the coordinator holds a state it may push from — either the
    /// initial pull landed, or a previous run left persisted unpushed changes
    /// (in which case local, not cloud, is the current truth). Gates
    /// `requestPush` so a mutation can never push seed/partial state.
    private var isArmed = false
    /// True once cloud state has been merged into the cache during this
    /// coordinator's life.
    ///
    /// This used to be a *safety* gate — a push from a cache that had never
    /// seen the cloud would prune away every row another device had added.
    /// Deleting no longer works that way (see `deleteTombstonedRecords`), so
    /// what is left is convergence: pulling the other device's records in
    /// before pushing keeps the two caches from drifting for a whole session,
    /// and it is what puts plan child ids into `observedPrunableIds` so the
    /// plan reconcile has something to work from.
    private var hasMergedCloudState = false
    /// True only while the most recent cloud read reached EOF on the tables a
    /// push still prunes — the active plan's day/exercise/set rows.
    ///
    /// Separate from `hasMergedCloudState` because the two answer different
    /// questions: that one is "have we looked at the cloud at all?", this one
    /// is "was what we saw the *whole* table?". A truncated read (Issue #30)
    /// still merges fine — merging only adds rows — but the resulting local
    /// state is missing every row past the cutoff, so using it as the
    /// authority for an absence-based prune would delete exactly those rows.
    /// Assigned, not OR-ed: a later truncated read invalidates an earlier
    /// complete one, because the cache can no longer be shown to cover the
    /// cloud.
    ///
    /// Scoped to the prunable tables rather than all of them because a global
    /// flag made an unrelated table veto the plan prune: a user whose
    /// `exercise_sets` read truncated would have their plan edits acknowledged
    /// but never reconciled, and the next pull would quietly restore what they
    /// deleted. Record deletions do not consult this at all any more — they
    /// are durable tombstones, so an incomplete read delays them instead of
    /// dropping them (Issue #132).
    private var hasCompletePrunableView = false
    /// Ids of prunable rows this device has provably held: what the last cloud
    /// read returned, plus what our own successful pushes put there.
    ///
    /// A prune may only destroy ids in here. Reaching EOF proves we saw the
    /// end of the table, not that we saw every row in it — a row another
    /// device inserted below our cursor mid-scan is missing from the snapshot
    /// for a reason that has nothing to do with the user having deleted it.
    private var observedPrunableIds: [String: Set<String>] = [:]
    private(set) var hasUnpushedChanges = false
    private(set) var lastErrorDescription: String?
    private let onStatusChange: (@Sendable (CloudSyncStatus) -> Void)?

    /// Sync failures are otherwise invisible (no UI consumes the error text
    /// today), which let a deterministic push failure go unnoticed for days —
    /// keep them findable in Console.app.
    private static let logger = Logger(subsystem: "com.max.PeakLog", category: "CloudSync")

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
    ///
    /// Exception: when the previous run left persisted unpushed changes,
    /// local is the truth and the order inverts to push-first (see below).
    @discardableResult
    func start() async -> Bool {
        guard await database.isCloudSyncSafe() else {
            let message = "Local data needs recovery before cloud sync can start."
            lastErrorDescription = message
            onStatusChange?(.pendingRetry(message))
            return false
        }
        await database.prepareForCloudUser(userId)
        // A previous run persisted mutations the cloud never confirmed —
        // local is the truth right now, so push first instead of pulling.
        // A full `pull()` here would merge cloud-as-truth over the unpushed
        // edits and silently revert them (the restart-lost-edits bug).
        // `performPush` still folds in cloud-only *records* before it prunes
        // (see `mergeCloudRecordsPreservingLocalEdits`), and its revision
        // guard still pull-merges when a server-side replan landed.
        if await database.hasUnpushedLocalChanges() {
            hasUnpushedChanges = true
            isArmed = true
            await installChangeHook()
            await requestPush()
            // Even if the push failed (still offline), stay armed on local
            // state; `onForeground` retries the push rather than pulling.
            return true
        }
        guard await pull() else { return false }
        isArmed = true
        await installChangeHook()
        return true
    }

    func stop() async {
        await database.disarmCloudSync(userId: userId)
    }

    /// On returning to the foreground: if we owe the cloud a push, retry it;
    /// otherwise pull to pick up anything changed on another device. Before
    /// the coordinator is armed this re-runs `start()`, which also rechecks
    /// the persisted outbox — an edit made while the initial pull kept
    /// failing offline must be pushed, not overwritten by the retried pull.
    func onForeground() async {
        guard isArmed else {
            await start()
            return
        }
        if hasUnpushedChanges {
            await requestPush()
        } else {
            await pull()
        }
    }

    // MARK: - Pull

    @discardableResult
    func pull() async -> Bool {
        guard await database.isCloudSyncSafe() else {
            let message = "Local data needs recovery before cloud sync can continue."
            lastErrorDescription = message
            onStatusChange?(.pendingRetry(message))
            return false
        }
        do {
            let snapshot = try await loader.load(userId: userId)
            // Merge (not replace) so offline user records survive the login
            // pull while seed rows are still dropped. See Issue #1 /
            // `LocalAppDatabase.mergeFromCloud`.
            //
            // A truncated read is still merged: showing the user the first N
            // thousand rows beats showing nothing, and merging cannot lose
            // data. What it must not do is unlock the destructive half of the
            // next push — hence the separate completeness flag below.
            await database.mergeFromCloud(
                profile: snapshot.data.profile,
                activePlan: snapshot.data.activePlan,
                strengthSessions: snapshot.data.strengthSessions,
                runningRecords: snapshot.data.runningRecords,
                customExercises: snapshot.data.customExercises,
                goalSpec: snapshot.data.goalSpec
            )
            hasMergedCloudState = true
            noteCloudViewCompleteness(snapshot)
            lastErrorDescription = nil
            return true
        } catch {
            let description = "\(error)"
            Self.logger.error("cloud pull failed: \(description, privacy: .public)")
            lastErrorDescription = "pull: \(description)"
            onStatusChange?(.pendingRetry(description))
            return false
        }
    }

    /// Folds cloud-only *records* (strength sessions, cardio records, custom
    /// exercises) into the cache while leaving the local plan, profile and
    /// goal spec untouched — the half of a pull that cannot lose unpushed
    /// local edits, because record merging is last-write-wins on `updatedAt`
    /// and keeps local-only user rows.
    ///
    /// Run before the first push of a coordinator's life. It used to be a
    /// correctness requirement — the push reconciled full state, so its
    /// `deleteNotIn` would delete any row another device had added while this
    /// one was away. That is no longer how deleting works (Issue #132:
    /// `deleteTombstonedRecords` names its rows), so this is now about
    /// convergence and about giving the plan reconcile an observed id set to
    /// work from, not about keeping the push from destroying data.
    private func mergeCloudRecordsPreservingLocalEdits() async throws {
        let snapshot = try await loader.load(userId: userId)
        await database.mergeCloudRecordsPreservingLocalState(
            strengthSessions: snapshot.data.strengthSessions,
            runningRecords: snapshot.data.runningRecords,
            customExercises: snapshot.data.customExercises
        )
        hasMergedCloudState = true
        noteCloudViewCompleteness(snapshot)
    }

    /// Records whether the cache may now be used as the authority for
    /// deleting, and says so in the log when it may not — a silently skipped
    /// prune is otherwise indistinguishable from a healthy no-op push.
    ///
    /// The observed set is *replaced*, not unioned: it describes what this
    /// read saw, and a row that has since been deleted elsewhere must not stay
    /// eligible forever on the strength of a read from an hour ago.
    private func noteCloudViewCompleteness(_ snapshot: CloudSnapshot) {
        hasCompletePrunableView = snapshot.isCompleteForPrunableTables
        observedPrunableIds = snapshot.observedPruneIds
        guard !snapshot.isComplete else { return }
        let tables = snapshot.incompleteTables.joined(separator: ", ")
        Self.logger.error(
            "cloud read truncated for \(tables, privacy: .public); prune disabled until a complete read lands"
        )
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
        guard isArmed else { return }
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
                lastErrorDescription = nil
            } catch {
                // Leave hasUnpushedChanges set so onForeground retries later
                // (and, persisted in the database, so a cold start after a
                // kill pushes instead of pulling over the unpushed edits).
                let description = "\(error)"
                Self.logger.error("cloud push failed: \(description, privacy: .public)")
                lastErrorDescription = "push: \(description)"
                onStatusChange?(.pendingRetry(description))
                return
            }
        } while pushAgain
        // Cleared only once the whole coalescing loop drains: clearing after
        // each performPush would leave the flag false when a queued re-run
        // (pushAgain) subsequently fails, and onForeground would then pull
        // over the very mutation that re-run was carrying.
        hasUnpushedChanges = false
        onStatusChange?(.idle)
    }

    private func performPush() async throws {
        // Fold in cloud-only records before pushing from a cache that has
        // never seen cloud state (the push-first cold start, or a foreground
        // retry whose initial pull failed). This is no longer load-bearing for
        // the record tables — nothing below can delete a row it has not heard
        // of — but it is what stops the two caches drifting for a session, and
        // it is what fills `observedPrunableIds` for the plan reconcile.
        // Throwing on failure leaves the persisted dirty flag set, so the
        // edits stay local and the next foreground retries — the same outcome
        // a failed initial pull had before push-first existed.
        if !hasMergedCloudState {
            try await mergeCloudRecordsPreservingLocalEdits()
        }

        var snapshot = await database.snapshot()

        // Revision guard (Phase 3): if the server's copy of the active plan
        // advanced since our last pull — a server-side replan landed while we
        // were holding unpushed local changes — we MUST pull-merge before
        // pushing. Otherwise the child-table prune below would delete the
        // freshly replanned rows and re-upsert our stale ones, silently
        // undoing the replan the user just saw. Pulling first folds the replan
        // into the local cache (offline completions preserved, per Issue #1),
        // and re-snapshotting picks it up so the push echoes it back intact.
        // See Phase 3 plan §4.2/§4.3.
        if try await serverPlanRevisionAdvanced(beyond: snapshot.activePlan) {
            guard await pull() else { throw CloudSyncError.requiredPullFailed }
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

        // These rows are now provably in the cloud and came from this device,
        // so they join the set a later prune may reconcile. Recorded here,
        // immediately after the upserts and *before* anything that can throw:
        // if the prune below failed and the user then deleted one of these
        // rows, a retry would find it in the cloud, refuse to delete it for
        // never having been observed, and acknowledge clean — leaving the next
        // pull to restore what the user deleted.
        noteRowsPushed(table: "training_plan_days", ids: bundle.planDays.map(\.id))
        noteRowsPushed(table: "training_plan_exercises", ids: bundle.planExercises.map(\.id))
        noteRowsPushed(table: "training_plan_sets", ids: bundle.planSets.map(\.id))

        // Append-only: insert, skipping rows the cloud already has (a retried
        // push resending the same client-generated ids), never pruned or
        // overwritten (RLS grants plan_edit_events no UPDATE policy). Cleared
        // locally only once the cloud confirms receipt.
        if !bundle.editEvents.isEmpty {
            try await client.insertIgnoringDuplicates(table: "plan_edit_events", rows: bundle.editEvents)
            await database.clearPushedEditEvents(ids: Set(bundle.editEvents.map(\.id)))
        }

        try await deleteTombstonedRecords(in: snapshot)

        // Prune the *plan child* rows the cloud has but the local cache no
        // longer does. Children first so a parent delete never strands a child
        // mid-request.
        //
        // Only the plan child tables are reconciled this way. The five record
        // tables used to be in this list too, and that was Issue #132: a prune
        // derives the doomed set from "present in the cloud, absent locally",
        // which describes a row this device deleted *and equally* a row
        // another device added while this one was away. They now go through
        // `deleteTombstonedRecords` above, which names the ids the user
        // actually deleted and can therefore never touch a row it has not
        // heard of.
        //
        // The plan keeps the absence protocol because absence really does
        // describe it: the cache holds the *whole* active plan, never a slice
        // of it, and the only writer that restructures a plan behind this
        // device's back is the server-side replan — which bumps `revision`,
        // which the guard above forces a pull-merge on before we get here. The
        // scope filter keeps that reconcile inside the active plan (SY2), so
        // an archived week's rows are untouched.
        //
        // Gated on a *complete* cloud read (Issue #30): after a truncated read
        // every row past the cutoff looks deleted. Skipping is the safe
        // direction — the cloud keeps rows it should have dropped, and the
        // next push after a complete read drops them — whereas throwing would
        // only strand the push while the truncation persists. Record
        // *deletions* no longer depend on this gate at all: they are durable
        // tombstones, so an incomplete read delays them instead of dropping
        // them on the floor.
        //
        // training_plans is intentionally NEVER pruned (SY1): the local cache
        // only ever holds the current week, so pruning by "not present
        // locally" would delete every past week's plan on the push right
        // after each rotation — destroying the history Phase 2's learning
        // loop depends on.
        if !hasCompletePrunableView {
            Self.logger.error("push skipped plan prune: no complete plan read yet")
        }
        let activePlanScope = [URLQueryItem(name: "plan_id", value: "eq.\(snapshot.activePlan.id)")]
        _ = try await client.prune(
            targets: [
                planPruneTarget(table: "training_plan_sets", keepIds: bundle.planSets.map(\.id), scope: activePlanScope),
                planPruneTarget(table: "training_plan_exercises", keepIds: bundle.planExercises.map(\.id), scope: activePlanScope),
                planPruneTarget(table: "training_plan_days", keepIds: bundle.planDays.map(\.id), scope: activePlanScope)
            ],
            keepIdsAreComplete: hasCompletePrunableView,
            // Logged from the callback rather than from the return value: a
            // prune that throws on its third delete batch has still destroyed
            // the first two, and only the callback has already run for those.
            didDelete: { Self.logPruneOutcome($0) }
        )

        // The cloud now holds everything up to the snapshot we sent; clear
        // the persisted "owes a push" flag (no-op if a mutation landed
        // mid-push — the coalescing loop re-pushes and re-acknowledges).
        await database.acknowledgePushedState(mutationSeq: snapshot.mutationSeq)
    }

    /// One plan child table's prune target, carrying the ids this device has
    /// actually observed so the diff can never reach a row it has not seen.
    private func planPruneTarget(
        table: String,
        keepIds: [String],
        scope: [URLQueryItem]
    ) -> CloudPruneTarget {
        CloudPruneTarget(
            table: table,
            keepIds: keepIds,
            observedIds: observedPrunableIds[table] ?? [],
            filters: scope
        )
    }

    private func noteRowsPushed(table: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        observedPrunableIds[table, default: []].formUnion(ids)
    }

    /// Deletes exactly the records the user deleted — the ids the local
    /// tombstone log names — and retires each table's tombstones the moment
    /// its request lands.
    ///
    /// This is the Issue #132 fix. The push no longer asks the cloud "drop
    /// everything I don't have"; it says "drop these". A row device B inserted
    /// after this device's last read is simply not in the log, so no ordering
    /// of the two devices' pushes can destroy it, and no amount of re-reading
    /// before the push is needed to make that true.
    ///
    /// Clearing per table rather than once at the end is the same reasoning as
    /// the prune audit log: if `running_workouts` fails after
    /// `workout_sessions` succeeded, the sessions really are gone and their
    /// tombstones must not survive to be re-sent — while the running
    /// tombstones must, so the next push retries them. `clearPushedRecordDeletions`
    /// subtracts rather than clears, so a deletion the user makes *during* the
    /// push keeps its tombstone.
    private func deleteTombstonedRecords(in snapshot: LocalDataSnapshot) async throws {
        let targets = snapshot.pendingRecordDeletions.deleteTargets(
            excluding: RecordIdentitySet(snapshot: snapshot),
            customExerciseCloudId: CloudMapper.strippedCustomId
        )
        for target in targets {
            try await client.deleteIds(table: target.table, ids: target.ids)
            Self.logPruneOutcome(CloudPruneOutcome(table: target.table, deletedIds: target.ids))
            // Throws if the confirmation cannot be written down. Failing the
            // push here is the point: acknowledging it clean while the retired
            // tombstones are still on disk would leave a restart holding a
            // deletion intent nothing is going to re-send or clear. The DELETE
            // is delete-by-id, so the retry re-sending it is a no-op.
            try await database.clearPushedRecordDeletions(target.confirmation)
        }
    }

    /// Deleting is the only irreversible thing sync does and the only thing a
    /// user can never recover from, so every deleted id goes to the log. Ids
    /// are `.public` because they are client-generated UUIDs carrying no user
    /// content, and without them a report of "my workouts vanished" is
    /// unanswerable after the fact.
    ///
    /// `static` so it can be handed to `prune` as a `@Sendable` callback
    /// without capturing the actor — the point of logging from the callback is
    /// that it runs *before* the next batch is attempted, so the entry exists
    /// even when a later batch throws and unwinds the whole push.
    private static func logPruneOutcome(_ outcome: CloudPruneOutcome) {
        logger.notice(
            """
            cloud prune deleted \(outcome.deletedIds.count, privacy: .public) row(s) \
            from \(outcome.table, privacy: .public): \
            \(outcome.deletedIds.joined(separator: ","), privacy: .public)
            """
        )
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

private enum CloudSyncError: LocalizedError {
    case requiredPullFailed

    var errorDescription: String? {
        switch self {
        case .requiredPullFailed:
            return "Required cloud pull failed; push was not attempted."
        }
    }
}

/// Minimal projection for the revision guard's single-column probe.
private struct TrainingPlanRevisionRow: Decodable, Sendable {
    let revision: Int
}
