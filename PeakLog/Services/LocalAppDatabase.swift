import Foundation

// MARK: - Cloud merge support

/// Records that carry an `updatedAt` can be merged by last-write-wins on a
/// login pull, instead of the cloud snapshot blindly overwriting offline
/// creations. Used by `LocalAppDatabase.mergeFromCloud` (Issue #1 fix).
nonisolated protocol CloudMergeableRecord: Sendable {
    var id: String { get }
    var updatedAt: Date { get }
}

extension WorkoutSession: CloudMergeableRecord {}
extension RunningWorkoutRecord: CloudMergeableRecord {}

// MARK: - Exercise PR computation

/// Computes each exercise's personal record (heaviest set) across the given
/// sessions. Weights are compared normalized to kilograms (`maxWeightKg`) so
/// that mixed kg/lbs sets are judged correctly — e.g. a 150lbs set (~68kg)
/// must not be treated as a PR over a 90kg set just because 150 > 90.
nonisolated func makeExercisePRs(from sessions: [WorkoutSession]) -> [String: ExercisePR] {
    var prsByExercise: [String: ExercisePR] = [:]
    for session in sessions {
        for exercise in session.exercises {
            let normalizedName = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let maxSet = exercise.sets.compactMap({ set -> (Double, WeightUnit)? in
                guard let weight = set.weight else { return nil }
                return (weight, set.weightUnit)
            }).max(by: { $0.0 * $0.1.toKilogramsFactor < $1.0 * $1.1.toKilogramsFactor }) else {
                continue
            }

            let candidate = ExercisePR(
                normalizedName: normalizedName,
                displayName: exercise.name,
                maxWeight: maxSet.0,
                weightUnit: maxSet.1,
                achievedAt: session.date
            )

            if let existing = prsByExercise[normalizedName], existing.maxWeightKg >= candidate.maxWeightKg {
                continue
            }
            prsByExercise[normalizedName] = candidate
        }
    }
    return prsByExercise
}

/// A row id is "user-generated" (and thus worth preserving across a login
/// pull) when — after stripping the `custom-` prefix used by custom exercises
/// — it parses as a UUID. Seed/demo rows use deterministic non-UUID ids
/// (`local-plan`, `seed-session-1`, `plan-day-1`, …) and are intentionally
/// dropped so they never get pushed to the cloud (the original pull-first
/// intent); only real offline user data survives the merge.
private extension String {
    /// `nonisolated` because every caller is inside the `LocalAppDatabase`
    /// actor or one of its `nonisolated` value types; without it the default
    /// main-actor isolation makes each use a concurrency warning (an error
    /// under the Swift 6 language mode).
    nonisolated var isUserGeneratedID: Bool {
        let trimmed = hasPrefix("custom-") ? String(dropFirst("custom-".count)) : self
        return UUID(uuidString: trimmed) != nil
    }
}

private extension RecordIdentitySet {
    /// The five record tables' ids as they stand in one local state.
    /// `nonisolated` for the same reason as `isUserGeneratedID` above.
    nonisolated init(state: LocalAppState) {
        self.init(
            strengthSessions: state.strengthSessions,
            runningRecords: state.runningRecords,
            customExercises: state.customExercises
        )
    }
}

nonisolated private struct LocalAppState: Codable, Sendable {
    var ownerUserId: String?
    var profile: UserProfile
    var activePlan: TrainingPlan
    var strengthSessions: [WorkoutSession]
    var runningRecords: [RunningWorkoutRecord]
    var customExercises: [ExerciseDefinition]
    var goalSpec: GoalSpec?
    /// Not-yet-pushed edit events. Deliberately NOT overwritten by a pull
    /// (`replaceAll`) — a pull replaces cloud-mirrored *state*, but these are
    /// unpushed *facts*; overwriting them would silently lose history
    /// recorded while offline. See phase1 plan §4.3 / EV1.
    var pendingEditEvents: [PlanEditEvent]
    /// Monotonic counter backing `PlanEditEvent.clientSeq`. Persisted so a
    /// restart never reuses or rewinds a sequence number (EV3).
    var editEventSeq: Int64
    /// True while a signed-in user's local mutation has not been confirmed
    /// pushed to the cloud. Persisted (unlike the coordinator's in-memory
    /// copy) so a cold start knows it still owes the cloud a push — without
    /// this, `CloudSyncCoordinator.start()` pulled cloud-as-truth over the
    /// unpushed edits and every local change made before a failed push died
    /// with the process (the restart-lost-edits bug).
    var hasUnpushedChanges: Bool
    /// Monotonic counter bumped by every owned mutation. A push snapshots it
    /// and acknowledges that value on success, so a mutation landing while a
    /// push is in flight can never be wrongly marked clean.
    var localMutationSeq: Int64
    /// Records this device deleted that the cloud has not confirmed dropping
    /// yet. Persisted in the same atomic write as the deletion itself, for the
    /// same reason `hasUnpushedChanges` is: a kill between the delete and its
    /// push must not lose the fact that the user deleted something. See
    /// `RecordDeletionLog` for why deletion is an explicit intent here rather
    /// than an absence inferred at push time (Issue #132).
    var pendingRecordDeletions: RecordDeletionLog
    /// Newest `record_deletions.deleted_at` a completed pull has applied — the
    /// cursor for the next incremental read of the server deletion log
    /// (Issue #148). A **server** timestamp, so no device's clock can move it.
    /// nil means "never read the log", which makes the next pull read the whole
    /// retained window: the correct behaviour on a first sync and after a
    /// reinstall alike.
    var recordDeletionsSyncedThrough: Date?
    /// Device-clock time of the last completed deletion-log pull. Diagnostics
    /// only — nothing branches on it. It exists so the one degradation this
    /// protocol has (a device offline longer than the server's retention window
    /// never hears about deletions that expired meanwhile) shows up in the log
    /// instead of only as records quietly coming back.
    var recordDeletionsPulledAt: Date?

    init(
        ownerUserId: String? = nil,
        profile: UserProfile,
        activePlan: TrainingPlan,
        strengthSessions: [WorkoutSession],
        runningRecords: [RunningWorkoutRecord],
        customExercises: [ExerciseDefinition] = [],
        goalSpec: GoalSpec? = nil,
        pendingEditEvents: [PlanEditEvent] = [],
        editEventSeq: Int64 = 0,
        hasUnpushedChanges: Bool = false,
        localMutationSeq: Int64 = 0,
        pendingRecordDeletions: RecordDeletionLog = RecordDeletionLog(),
        recordDeletionsSyncedThrough: Date? = nil,
        recordDeletionsPulledAt: Date? = nil
    ) {
        self.ownerUserId = ownerUserId
        self.profile = profile
        self.activePlan = activePlan
        self.strengthSessions = strengthSessions
        self.runningRecords = runningRecords
        self.customExercises = customExercises
        self.goalSpec = goalSpec
        self.pendingEditEvents = pendingEditEvents
        self.editEventSeq = editEventSeq
        self.hasUnpushedChanges = hasUnpushedChanges
        self.localMutationSeq = localMutationSeq
        self.pendingRecordDeletions = pendingRecordDeletions
        self.recordDeletionsSyncedThrough = recordDeletionsSyncedThrough
        self.recordDeletionsPulledAt = recordDeletionsPulledAt
    }

    // Custom decode keeps state files written before newer fields existed loadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ownerUserId = try container.decodeIfPresent(String.self, forKey: .ownerUserId)
        profile = try container.decode(UserProfile.self, forKey: .profile)
        activePlan = try container.decode(TrainingPlan.self, forKey: .activePlan)
        strengthSessions = try container.decode([WorkoutSession].self, forKey: .strengthSessions)
        runningRecords = try container.decode([RunningWorkoutRecord].self, forKey: .runningRecords)
        customExercises = try container.decodeIfPresent([ExerciseDefinition].self, forKey: .customExercises) ?? []
        goalSpec = try container.decodeIfPresent(GoalSpec.self, forKey: .goalSpec)
        pendingEditEvents = try container.decodeIfPresent([PlanEditEvent].self, forKey: .pendingEditEvents) ?? []
        editEventSeq = try container.decodeIfPresent(Int64.self, forKey: .editEventSeq) ?? 0
        hasUnpushedChanges = try container.decodeIfPresent(Bool.self, forKey: .hasUnpushedChanges) ?? false
        localMutationSeq = try container.decodeIfPresent(Int64.self, forKey: .localMutationSeq) ?? 0
        // Absent in state files written before tombstones existed. An empty
        // log is the only *possible* default — the old format recorded which
        // rows were gone nowhere but in their absence, so there is nothing to
        // reconstruct from — but it is not a lossless one, and the gap is
        // worth naming rather than glossing.
        //
        // If such a file was clean, the old client's absence-prune had already
        // carried its deletions to the cloud and nothing is owed. If it was
        // dirty (`hasUnpushedChanges`) *because of a deletion*, that intent is
        // lost: the cloud row survives, and the first pull merges it back.
        //
        // Reconstructing it is not merely risky, it is **not decidable from the
        // data available**. The only signal is "this row is in the cloud and
        // not in my cache", which has two explanations — this device deleted
        // it, or another device added it after this cache's last read — and
        // nothing in an old-format file distinguishes them. It holds no
        // record of when it last read the cloud, and timestamps do not help:
        // in the exact scenario Issue #132 is about, the other device's push
        // is *older* than this device's local edit, so "my copy of the parent
        // session is newer" is true for both explanations. Guessing wrong in
        // one direction destroys another device's data permanently; guessing
        // wrong in the other resurfaces a record the user deletes again. So
        // the empty default stands, and this is a one-shot loss bounded to
        // upgrades that happen mid-outbox.
        //
        // What Issue #148 changes is the *class*: from this version on the
        // intent is also recorded server-side (an AFTER DELETE trigger writes
        // `record_deletions`), so once a deletion has been pushed even once it
        // no longer depends on this file surviving — a reinstall, a corrupt
        // state file or a future format change cannot lose it, and every other
        // device is told about it. The local state file has stopped being the
        // single point of failure for deletion intent; it just cannot answer
        // for deletions that predate it being asked.
        pendingRecordDeletions = try container.decodeIfPresent(
            RecordDeletionLog.self, forKey: .pendingRecordDeletions
        ) ?? RecordDeletionLog()
        // Absent before Issue #148. nil is both the correct default and the
        // safe one: it makes the next pull read the entire retained tombstone
        // window rather than assuming this cache is already caught up.
        recordDeletionsSyncedThrough = try container.decodeIfPresent(
            Date.self, forKey: .recordDeletionsSyncedThrough
        )
        recordDeletionsPulledAt = try container.decodeIfPresent(
            Date.self, forKey: .recordDeletionsPulledAt
        )
    }
}

nonisolated enum LocalStateRecoveryStatus: Equatable, Sendable {
    case healthy
    case recoveryRequired
}

actor LocalAppDatabase {
    static let shared = LocalAppDatabase()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: LocalAppState
    /// Last state known to be coherent with the local cache. Mutations are
    /// applied to `state` before encoding; this baseline lets `persist()` roll
    /// back an in-memory mutation when the write fails.
    private var lastPersistedState: LocalAppState
    private let recoveryStatus: LocalStateRecoveryStatus

    /// Set whenever a mutation invalidates `state.profile.stats` /
    /// `exercisePRs` (streak, volume, PRs) instead of eagerly recomputing
    /// them. `recalculateDerivedProfile()` is an O(N) walk over every session
    /// and set, so running it on every single mutation makes each write
    /// (and the full-state JSON re-encode that follows) cost more as
    /// training history grows. Deferring the recompute to the next read
    /// (`fetchProfile()` / `snapshot()`) collapses a burst of mutations into
    /// a single recompute (Issue #17).
    private var derivedProfileIsStale = false

    /// Fired after a mutation persists locally, so the cloud syncer can push.
    /// Installed by `CloudSyncCoordinator` only when signed in; nil in DEBUG
    /// local mode, which keeps that mode fully offline. A full `replaceAll`
    /// (a pull writing cloud truth into the cache) deliberately does NOT fire
    /// it — otherwise every pull would echo straight back as a push.
    private var onChange: (@Sendable () -> Void)?

    /// The signed-in user plan-edit events are currently being recorded for.
    /// nil while signed out or in DEBUG local mode, which keeps both of those
    /// paths from accumulating events nobody will ever push (EV8).
    private var armedUserId: String?

    /// Events dropped by the soft cap this launch — diagnostic only, not
    /// persisted (EV12).
    private var droppedEditEventCount = 0

    private static let maxPendingEditEvents = 5000

    /// Arms plan-edit-event recording for `userId` and installs the push
    /// hook, in one call so they can never be out of sync. Call once the
    /// initial pull has landed (see `CloudSyncCoordinator.start`), so a
    /// mutation made right after sign-in is never silently unrecorded.
    ///
    /// Discards any pending events left over from a *different* account
    /// (EV9): without this, a stale event recorded under account A — still
    /// sitting in `pendingEditEvents` because its push kept failing — would
    /// otherwise get swept up in account B's next push. `CloudMapper` stamps
    /// every pushed row with the *current* signed-in user, so that event
    /// would be silently mis-attributed to B rather than merely rejected.
    func armCloudSync(userId: String, onChange: @escaping @Sendable () -> Void) {
        guard recoveryStatus == .healthy else { return }
        self.armedUserId = userId
        self.onChange = onChange
        state.pendingEditEvents.removeAll { $0.userId != userId }
        lastPersistedState = state
    }

    func disarmCloudSync(userId: String) {
        guard armedUserId == userId else { return }
        armedUserId = nil
        onChange = nil
    }

    /// Enters the signed-in user's local account boundary before any pull or
    /// push. A different (or legacy unowned) cache is discarded so a failed
    /// first pull can never expose or upload the previous account's records.
    func prepareForCloudUser(_ userId: String) {
        guard recoveryStatus == .healthy else { return }
        guard state.ownerUserId != userId else { return }
        var cleanState = Self.makeSeedState()
        cleanState.ownerUserId = userId
        state = cleanState
        armedUserId = nil
        onChange = nil
        if (try? writeStateToDisk()) != nil {
            lastPersistedState = state
        } else {
            state = lastPersistedState
        }
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            if let data = try? Data(contentsOf: self.fileURL),
               let loaded = try? decoder.decode(LocalAppState.self, from: data) {
                self.state = loaded
                self.lastPersistedState = loaded
                self.recoveryStatus = .healthy
            } else {
                self.state = Self.makeSeedState()
                self.lastPersistedState = self.state
                self.recoveryStatus = .recoveryRequired
                Self.backUpUnreadableState(at: self.fileURL)
            }
        } else {
            let seeded = Self.makeSeedState()
            self.state = seeded
            self.lastPersistedState = seeded
            self.recoveryStatus = .healthy
            try? Self.ensureParentDirectoryExists(for: self.fileURL)
            if let data = try? encoder.encode(seeded) {
                try? data.write(to: self.fileURL, options: [.atomic])
            }
        }
    }

    func fetchProfile() -> UserProfile {
        refreshDerivedProfileIfNeeded()
        return state.profile
    }

    func updatePreferences(_ prefs: UpdatePreferencesRequest) throws -> UserPreferences {
        if let value = prefs.notificationsEnabled {
            state.profile.preferences.notificationsEnabled = value
        }
        if let value = prefs.weightUnit {
            state.profile.preferences.weightUnit = value
        }
        if let value = prefs.timezone {
            state.profile.preferences.timezone = value
        }
        if let value = prefs.language {
            state.profile.preferences.language = value
        }

        try persist()
        return state.profile.preferences
    }

    func updateFitnessGoalSummary(_ summary: String) throws -> String {
        let before = state.profile.fitnessGoalSummary
        state.profile.fitnessGoalSummary = summary
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.activePlan = rebuildPlan(
                from: state.activePlan,
                goalSummary: summary,
                coachSummary: state.activePlan.coachSummary
            )
        }
        appendEditEvent(
            type: .goalChanged,
            payload: .from(GoalTextChangedPayload(before: before, after: summary))
        )
        try persist()
        return summary
    }

    func goalSpec() -> GoalSpec? {
        state.goalSpec
    }

    /// Saves the structured goal. Deliberately does not touch `activePlan` —
    /// unlike `updateFitnessGoalSummary`'s legacy free-text path, changing the
    /// goal mid-week must not rebuild the current plan (G4); the next
    /// Phase-2 generation picks it up naturally.
    func updateGoalSpec(_ spec: GoalSpec) throws -> GoalSpec {
        let before = state.goalSpec
        state.goalSpec = spec
        appendEditEvent(
            type: .goalChanged,
            payload: .from(GoalSpecChangedPayload(before: before, after: spec))
        )
        try persist()
        return spec
    }

    /// Records a one-tap mid-week signal (Phase 3) as a `user`-sourced edit
    /// event. No plan mutation happens here — the Agent's structural response
    /// is applied server-side and pulled back down. Recording the signal
    /// locally (and pushing it via the normal event pipeline) means it reaches
    /// the next weekly generation's learning context even if the replan
    /// request itself fails.
    func recordDaySignal(_ signal: ReplanSignal) throws {
        let today = Self.planDateString(from: Date())
        let day = state.activePlan.days.first(where: { $0.planDate == today })
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day?.id,
            planDate: today,
            type: .daySignal,
            payload: .object(["signal": .string(signal.rawValue)])
        )
        try persist()
    }

    func customExercises() -> [ExerciseDefinition] {
        state.customExercises
    }

    func addCustomExercise(
        name: String,
        muscleGroup: MuscleGroup,
        loadType: ExerciseLoadType
    ) throws -> ExerciseDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAppDatabaseError.invalidCustomExerciseName
        }

        if let existing = state.customExercises.first(where: {
            ExerciseDefinition.normalize($0.nameEN) == ExerciseDefinition.normalize(trimmed)
                || ExerciseDefinition.normalize($0.nameZH) == ExerciseDefinition.normalize(trimmed)
        }) {
            return existing
        }

        let definition = ExerciseDefinition(
            id: "custom-\(UUID().uuidString.lowercased())",
            nameEN: trimmed,
            nameZH: trimmed,
            aliases: [],
            muscleGroup: muscleGroup,
            equipment: loadType == .bodyweight ? .bodyweight : .other,
            loadType: loadType,
            popularity: 0,
            isCustom: true
        )
        state.customExercises.append(definition)
        try persist()
        return definition
    }

    func activePlan() -> TrainingPlan? {
        sanitizePlanCompletionLinks()
        return state.activePlan
    }

    func todayPlan() -> TrainingPlanDay? {
        sanitizePlanCompletionLinks()
        return state.activePlan.days.first(where: { $0.planDate == Self.planDateString(from: Date()) })
    }

    func activeDaysInMonth(year: Int, month: Int) -> [Date] {
        let calendar = Calendar.current
        let days = state.strengthSessions.map(\.date) + state.runningRecords.map(\.workoutDate)
        return Array(Set(days.map { calendar.startOfDay(for: $0) })).filter {
            calendar.component(.year, from: $0) == year && calendar.component(.month, from: $0) == month
        }
    }

    func allStrengthSessions() -> [WorkoutSession] {
        state.strengthSessions
    }

    func sessionsForDay(_ date: Date) -> [WorkoutSession] {
        let calendar = Calendar.current
        return state.strengthSessions
            .filter { calendar.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func runningRecordsForDay(_ date: Date) -> [RunningWorkoutRecord] {
        let calendar = Calendar.current
        return state.runningRecords
            .filter { calendar.isDate($0.workoutDate, inSameDayAs: date) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) throws -> RunningWorkoutRecord {
        let metrics = try CardioMetrics(
            activityType: .running,
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            rpe: nil
        )
        return try createCardioRecord(workoutDate: workoutDate, metrics: metrics, source: source)
    }

    func createCardioRecord(
        workoutDate: Date,
        metrics: CardioMetrics,
        source: RunningWorkoutSource
    ) throws -> CardioWorkoutRecord {
        let now = Date()
        let record = CardioWorkoutRecord(
            id: UUID().uuidString,
            userId: state.profile.id,
            workoutDate: workoutDate,
            activityType: metrics.activityType,
            durationMinutes: metrics.durationMinutes,
            distanceKm: metrics.distanceKm,
            rpe: metrics.rpe,
            source: source,
            createdAt: now,
            updatedAt: now
        )
        state.runningRecords.append(record)
        derivedProfileIsStale = true
        try persist()
        return record
    }

    func completePlannedCardio(
        planExerciseId: String,
        metrics: CardioMetrics
    ) throws -> CardioWorkoutRecord {
        guard let dayIndex = state.activePlan.days.firstIndex(where: { day in
            day.exercises.contains { $0.id == planExerciseId }
        }), let exerciseIndex = state.activePlan.days[dayIndex].exercises.firstIndex(where: {
            $0.id == planExerciseId
        }) else {
            throw LocalAppDatabaseError.planExerciseNotFound
        }

        let planItem = state.activePlan.days[dayIndex].exercises[exerciseIndex]
        guard planItem.itemType == .cardio, let plannedActivity = planItem.cardioActivityType else {
            throw LocalAppDatabaseError.planExerciseNotCardio
        }
        guard plannedActivity == metrics.activityType else {
            throw LocalAppDatabaseError.cardioActivityMismatch
        }
        guard !planItem.isCardioCompleted else {
            throw LocalAppDatabaseError.cardioAlreadyCompleted
        }

        let now = Date()
        let record = CardioWorkoutRecord(
            id: UUID().uuidString,
            userId: state.profile.id,
            workoutDate: Self.date(from: state.activePlan.days[dayIndex].planDate) ?? now,
            activityType: metrics.activityType,
            durationMinutes: metrics.durationMinutes,
            distanceKm: metrics.distanceKm,
            rpe: metrics.rpe,
            source: .manual,
            createdAt: now,
            updatedAt: now
        )
        state.runningRecords.append(record)
        state.activePlan.days[dayIndex].exercises[exerciseIndex].cardioCompletedAt = now
        state.activePlan.days[dayIndex].exercises[exerciseIndex].linkedCardioWorkoutId = record.id
        derivedProfileIsStale = true
        try persist()
        return record
    }

    func createStrengthSession(_ draft: StrengthSessionDraft) throws -> WorkoutSession {
        let now = Date()
        let session = WorkoutSession(
            id: UUID().uuidString,
            userId: state.profile.id,
            date: draft.workoutDate,
            durationMinutes: nil,
            label: draft.title,
            exercises: draft.exercises.enumerated().map { exerciseOffset, exercise in
                Exercise(
                    id: UUID().uuidString,
                    name: exercise.name,
                    exerciseId: exercise.exerciseId,
                    exerciseLoadType: exercise.exerciseLoadType,
                    sets: exercise.sets.enumerated().map { setOffset, set in
                        ExerciseSet(
                            id: UUID().uuidString,
                            setIndex: setOffset + 1,
                            weight: set.weight,
                            weightUnit: set.weightUnit,
                            reps: set.reps,
                            rpe: set.rpe
                        )
                    }
                )
            },
            createdAt: now,
            updatedAt: now
        )
        state.strengthSessions.append(session)
        derivedProfileIsStale = true
        try persist()
        return session
    }

    func updateSet(
        sessionId: String,
        exerciseId: String,
        setId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) throws -> ExerciseSet {
        guard let (sessionIndex, exerciseIndex, setIndex) = findSetIndices(sessionId: sessionId, exerciseId: exerciseId, setId: setId) else {
            throw LocalAppDatabaseError.setNotFound
        }

        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex].weight = weight
        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex].weightUnit = weightUnit
        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex].reps = reps
        state.strengthSessions[sessionIndex].updatedAt = Date()
        derivedProfileIsStale = true
        try persist()
        return state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex]
    }

    func addSet(
        sessionId: String,
        exerciseId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) throws -> ExerciseSet {
        guard let sessionIndex = state.strengthSessions.firstIndex(where: { $0.id == sessionId }) else {
            throw LocalAppDatabaseError.sessionNotFound
        }
        guard let exerciseIndex = state.strengthSessions[sessionIndex].exercises.firstIndex(where: { $0.id == exerciseId }) else {
            throw LocalAppDatabaseError.exerciseNotFound
        }

        let nextIndex = (state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.map(\.setIndex).max() ?? 0) + 1
        let newSet = ExerciseSet(
            id: UUID().uuidString,
            setIndex: nextIndex,
            weight: weight,
            weightUnit: weightUnit,
            reps: reps,
            rpe: nil
        )
        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.append(newSet)
        state.strengthSessions[sessionIndex].updatedAt = Date()
        derivedProfileIsStale = true
        try persist()
        return newSet
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) throws {
        guard let (sessionIndex, exerciseIndex, setIndex) = findSetIndices(sessionId: sessionId, exerciseId: exerciseId, setId: setId) else {
            throw LocalAppDatabaseError.setNotFound
        }

        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.remove(at: setIndex)
        normalizeSetIndices(for: sessionIndex, exerciseIndex: exerciseIndex)
        state.strengthSessions[sessionIndex].updatedAt = Date()
        derivedProfileIsStale = true
        try persist()
    }

    func updateSetRPE(setId: String, rpe: Double?) throws -> ExerciseSet {
        for sessionIndex in state.strengthSessions.indices {
            for exerciseIndex in state.strengthSessions[sessionIndex].exercises.indices {
                if let setIndex = state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) {
                    state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex].rpe = rpe
                    state.strengthSessions[sessionIndex].updatedAt = Date()
                    try persist()
                    return state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex]
                }
            }
        }
        throw LocalAppDatabaseError.setNotFound
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) throws -> TrainingPlanSet {
        guard let planLocation = findPlanSet(planSetId: planSetId) else {
            throw LocalAppDatabaseError.planSetNotFound
        }

        let now = Date()
        var day = state.activePlan.days[planLocation.dayIndex]
        let exercise = day.exercises[planLocation.exerciseIndex]

        let linkedSet = ExerciseSet(
            id: UUID().uuidString,
            setIndex: actualSetIndex(for: day.id, exerciseName: exercise.exerciseName),
            weight: actualWeight,
            weightUnit: actualWeightUnit,
            reps: actualReps,
            rpe: nil
        )

        // The strength session is created/extended for its side effect on
        // `state.strengthSessions`; the plan set only needs the linked set's id.
        _ = ensureStrengthSessionForPlanDay(
            day,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            exerciseLoadType: exercise.exerciseLoadType,
            linkedSet: linkedSet
        )
        day.exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].completedAt = now
        day.exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].linkedExerciseSetId = linkedSet.id
        state.activePlan.days[planLocation.dayIndex] = day

        derivedProfileIsStale = true
        try persist()

        return state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex]
    }

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) throws -> TrainingPlanSet {
        guard let planLocation = findPlanSet(planSetId: planSetId) else {
            throw LocalAppDatabaseError.planSetNotFound
        }
        let day = state.activePlan.days[planLocation.dayIndex]
        let exercise = day.exercises[planLocation.exerciseIndex]
        let before = PlannedSetSnapshot(exercise.sets[planLocation.setIndex])

        state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].targetWeight = targetWeight
        state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].targetWeightUnit = targetWeightUnit
        state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].targetReps = targetReps

        let updated = state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex]
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day.id,
            planDate: day.planDate,
            type: .setTargetUpdated,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            payload: .from(SetTargetUpdatedPayload(before: before, after: PlannedSetSnapshot(updated)))
        )
        try persist()
        return updated
    }

    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) throws -> TrainingPlanSet {
        guard let location = findPlanExercise(planExerciseId: planExerciseId) else {
            throw LocalAppDatabaseError.planExerciseNotFound
        }
        let day = state.activePlan.days[location.dayIndex]
        let exercise = day.exercises[location.exerciseIndex]
        let nextIndex = (exercise.sets.map(\.setIndex).max() ?? 0) + 1
        let set = TrainingPlanSet(
            id: UUID().uuidString,
            setIndex: nextIndex,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
        state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex].sets.append(set)
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day.id,
            planDate: day.planDate,
            type: .setAdded,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            payload: .from(PlannedSetSnapshot(set))
        )
        try persist()
        return set
    }

    func deletePlannedSet(planSetId: String) throws {
        guard let location = findPlanSet(planSetId: planSetId) else {
            throw LocalAppDatabaseError.planSetNotFound
        }
        let day = state.activePlan.days[location.dayIndex]
        let exercise = day.exercises[location.exerciseIndex]
        let removedSet = exercise.sets[location.setIndex]

        state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex].sets.remove(at: location.setIndex)
        for index in state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex].sets.indices {
            state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex].sets[index].setIndex = index + 1
        }
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day.id,
            planDate: day.planDate,
            type: .setRemoved,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            payload: .from(SetRemovedPayload(snapshot: PlannedSetSnapshot(removedSet), wasCompleted: removedSet.isCompleted))
        )
        try persist()
    }

    func deletePlannedExercise(planExerciseId: String) throws {
        guard let location = findPlanExercise(planExerciseId: planExerciseId) else {
            throw LocalAppDatabaseError.planExerciseNotFound
        }

        let day = state.activePlan.days[location.dayIndex]
        // 已完成组落库产生的训练记录一并删除，避免计划删掉后留下孤儿记录。
        let exercise = state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex]
        removeLoggedSets(withIds: Set(exercise.sets.compactMap(\.linkedExerciseSetId)))

        state.activePlan.days[location.dayIndex].exercises.remove(at: location.exerciseIndex)
        for index in state.activePlan.days[location.dayIndex].exercises.indices {
            state.activePlan.days[location.dayIndex].exercises[index].orderIndex = index
        }
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day.id,
            planDate: day.planDate,
            type: .exerciseRemoved,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            payload: .from(ExerciseRemovedPayload(
                snapshot: PlannedExerciseSnapshot(exercise),
                hadCompletedSets: exercise.sets.contains(where: \.isCompleted)
            ))
        )
        derivedProfileIsStale = true
        try persist()
    }

    func deleteExercise(sessionId: String, exerciseId: String) throws {
        // 今日记录是多个 session 合并展示的，exerciseId 不一定挂在传入的 session 下，找不到时退回全量查找。
        let sessionIndex = state.strengthSessions.firstIndex {
            $0.id == sessionId && $0.exercises.contains { $0.id == exerciseId }
        } ?? state.strengthSessions.firstIndex { $0.exercises.contains { $0.id == exerciseId } }
        guard let sessionIndex,
              let exerciseIndex = state.strengthSessions[sessionIndex].exercises.firstIndex(where: { $0.id == exerciseId })
        else {
            throw LocalAppDatabaseError.exerciseNotFound
        }

        let removedSetIds = Set(state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.map(\.id))
        state.strengthSessions[sessionIndex].exercises.remove(at: exerciseIndex)
        if state.strengthSessions[sessionIndex].exercises.isEmpty {
            state.strengthSessions.remove(at: sessionIndex)
        } else {
            state.strengthSessions[sessionIndex].updatedAt = Date()
        }
        clearPlanCompletionLinks(to: removedSetIds)
        derivedProfileIsStale = true
        try persist()
    }

    /// 删除散落在各 session 中的记录组；清空后的动作与 session 一并移除。
    private func removeLoggedSets(withIds setIds: Set<String>) {
        guard !setIds.isEmpty else { return }
        for sessionIndex in state.strengthSessions.indices {
            var didChange = false
            for exerciseIndex in state.strengthSessions[sessionIndex].exercises.indices {
                let before = state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.count
                state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.removeAll { setIds.contains($0.id) }
                guard state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.count != before else { continue }
                didChange = true
                normalizeSetIndices(for: sessionIndex, exerciseIndex: exerciseIndex)
            }
            if didChange {
                state.strengthSessions[sessionIndex].exercises.removeAll { $0.sets.isEmpty }
                state.strengthSessions[sessionIndex].updatedAt = Date()
            }
        }
        state.strengthSessions.removeAll { $0.exercises.isEmpty }
    }

    /// 记录被删除后，指向这些记录组的计划组回退为未完成。
    private func clearPlanCompletionLinks(to removedSetIds: Set<String>) {
        guard !removedSetIds.isEmpty else { return }
        for dayIndex in state.activePlan.days.indices {
            for exerciseIndex in state.activePlan.days[dayIndex].exercises.indices {
                for setIndex in state.activePlan.days[dayIndex].exercises[exerciseIndex].sets.indices {
                    guard let linkedId = state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex].linkedExerciseSetId,
                          removedSetIds.contains(linkedId) else { continue }
                    state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex].linkedExerciseSetId = nil
                    state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex].completedAt = nil
                }
            }
        }
    }

    /// `planDate`（"yyyy-MM-dd"）为 nil 时落到今天；传未来日期即把动作
    /// 安排到那一天，目标日不存在时按手动训练日新建（休息日 → 训练日）。
    func addPlannedExercises(_ drafts: [PlanExerciseDraft], planDate: String? = nil) throws -> TrainingPlanDay {
        guard !drafts.isEmpty,
              drafts.allSatisfy({ !$0.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LocalAppDatabaseError.invalidPlanExerciseName
        }

        let targetDateString = planDate ?? Self.planDateString(from: Date())

        if let dayIndex = state.activePlan.days.firstIndex(where: { $0.planDate == targetDateString }) {
            var day = state.activePlan.days[dayIndex]
            let wasEmpty = day.exercises.isEmpty
            var addedExercises: [TrainingPlanExercise] = []
            for draft in drafts {
                let exercise = makePlanExercise(from: draft, orderIndex: day.exercises.count)
                day.exercises.append(exercise)
                addedExercises.append(exercise)
            }
            if wasEmpty {
                day = TrainingPlanDay(
                    id: day.id,
                    planDate: day.planDate,
                    dayIndex: day.dayIndex,
                    title: String(localized: "today.plan.manual_day_title"),
                    focus: day.focus,
                    status: "planned",
                    exercises: day.exercises
                )
            }
            state.activePlan.days[dayIndex] = day
            for exercise in addedExercises {
                appendEditEvent(
                    planId: state.activePlan.id,
                    planDayId: day.id,
                    planDate: day.planDate,
                    type: .exerciseAdded,
                    exerciseName: exercise.exerciseName,
                    exerciseId: exercise.exerciseId,
                    payload: .from(PlannedExerciseSnapshot(exercise))
                )
            }
            try persist()
            return day
        }

        let exercises = drafts.enumerated().map { index, draft in
            makePlanExercise(from: draft, orderIndex: index)
        }
        let nextDayIndex = (state.activePlan.days.map(\.dayIndex).max() ?? 0) + 1
        let day = TrainingPlanDay(
            id: UUID().uuidString,
            planDate: targetDateString,
            dayIndex: nextDayIndex,
            title: String(localized: "today.plan.manual_day_title"),
            focus: nil,
            status: "planned",
            exercises: exercises
        )
        state.activePlan.days.append(day)
        for exercise in exercises {
            appendEditEvent(
                planId: state.activePlan.id,
                planDayId: day.id,
                planDate: day.planDate,
                type: .exerciseAdded,
                exerciseName: exercise.exerciseName,
                exerciseId: exercise.exerciseId,
                payload: .from(PlannedExerciseSnapshot(exercise))
            )
        }
        try persist()
        return day
    }

    /// `planDate` 为 nil 时重排今天，否则重排指定日期的计划日。
    func reorderPlannedExercises(orderedExerciseIds: [String], planDate: String? = nil) throws -> TrainingPlanDay {
        let targetDateString = planDate ?? Self.planDateString(from: Date())
        guard let dayIndex = state.activePlan.days.firstIndex(where: { $0.planDate == targetDateString }) else {
            throw LocalAppDatabaseError.planExerciseNotFound
        }
        let beforeNames = state.activePlan.days[dayIndex].exercises
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(\.exerciseName)
        guard let reorderedDay = state.activePlan.days[dayIndex].reordered(byExerciseIds: orderedExerciseIds) else {
            throw LocalAppDatabaseError.invalidExerciseOrder
        }
        let afterNames = reorderedDay.exercises
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(\.exerciseName)
        state.activePlan.days[dayIndex] = reorderedDay
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: reorderedDay.id,
            planDate: reorderedDay.planDate,
            type: .exercisesReordered,
            payload: .from(ExercisesReorderedPayload(before: beforeNames, after: afterNames))
        )
        try persist()
        return reorderedDay
    }

    private func makePlanExercise(from draft: PlanExerciseDraft, orderIndex: Int) -> TrainingPlanExercise {
        if draft.itemType == .cardio {
            return TrainingPlanExercise(
                id: UUID().uuidString,
                orderIndex: orderIndex,
                exerciseName: draft.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines),
                exerciseId: nil,
                exerciseLoadType: .unknown,
                progressionMode: "manual",
                notes: nil,
                previousPerformanceSummary: nil,
                aiSuggestion: nil,
                sets: [],
                itemType: .cardio,
                cardioActivityType: draft.cardioActivityType,
                targetDurationMinutes: draft.targetDurationMinutes,
                targetDistanceKm: draft.targetDistanceKm,
                targetRPE: draft.targetRPE
            )
        }
        return TrainingPlanExercise(
            id: UUID().uuidString,
            orderIndex: orderIndex,
            exerciseName: draft.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines),
            exerciseId: draft.exerciseId,
            exerciseLoadType: draft.isBodyweight ? .bodyweight : .weighted,
            progressionMode: "manual",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: draft.sets.enumerated().map { index, set in
                TrainingPlanSet(
                    id: UUID().uuidString,
                    setIndex: index + 1,
                    targetWeight: set.targetWeight,
                    targetWeightUnit: set.targetWeightUnit,
                    targetReps: set.targetReps,
                    completedAt: nil,
                    linkedExerciseSetId: nil
                )
            }
        )
    }

    private func rebuildPlan(from plan: TrainingPlan, goalSummary: String?, coachSummary: String) -> TrainingPlan {
        TrainingPlan(
            id: plan.id,
            weekStartDate: plan.weekStartDate,
            goalSummary: goalSummary,
            coachSummary: coachSummary,
            days: plan.days
        )
    }

    private func findSetIndices(sessionId: String, exerciseId: String, setId: String) -> (Int, Int, Int)? {
        guard let sessionIndex = state.strengthSessions.firstIndex(where: { $0.id == sessionId }) else {
            return nil
        }
        guard let exerciseIndex = state.strengthSessions[sessionIndex].exercises.firstIndex(where: { $0.id == exerciseId }) else {
            return nil
        }
        guard let setIndex = state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) else {
            return nil
        }
        return (sessionIndex, exerciseIndex, setIndex)
    }

    private func findPlanExercise(planExerciseId: String) -> (dayIndex: Int, exerciseIndex: Int)? {
        for dayIndex in state.activePlan.days.indices {
            if let exerciseIndex = state.activePlan.days[dayIndex].exercises.firstIndex(where: { $0.id == planExerciseId }) {
                return (dayIndex, exerciseIndex)
            }
        }
        return nil
    }

    private func findPlanSet(planSetId: String) -> (dayIndex: Int, exerciseIndex: Int, setIndex: Int)? {
        for dayIndex in state.activePlan.days.indices {
            for exerciseIndex in state.activePlan.days[dayIndex].exercises.indices {
                if let setIndex = state.activePlan.days[dayIndex].exercises[exerciseIndex].sets.firstIndex(where: { $0.id == planSetId }) {
                    return (dayIndex, exerciseIndex, setIndex)
                }
            }
        }
        return nil
    }

    private func ensureStrengthSessionForPlanDay(
        _ day: TrainingPlanDay,
        exerciseName: String,
        exerciseId: String?,
        exerciseLoadType: ExerciseLoadType,
        linkedSet: ExerciseSet
    ) -> String {
        let sessionDate = Self.date(from: day.planDate) ?? Date()
        let calendar = Calendar.current

        if let sessionIndex = state.strengthSessions.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: sessionDate) }) {
            if let exerciseIndex = state.strengthSessions[sessionIndex].exercises.firstIndex(where: {
                $0.name.localizedCaseInsensitiveCompare(exerciseName) == .orderedSame
            }) {
                state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.append(linkedSet)
            } else {
                state.strengthSessions[sessionIndex].exercises.append(
                    Exercise(id: UUID().uuidString, name: exerciseName, exerciseId: exerciseId, exerciseLoadType: exerciseLoadType, sets: [linkedSet])
                )
            }
            state.strengthSessions[sessionIndex].updatedAt = Date()
            return state.strengthSessions[sessionIndex].id
        }

        let now = Date()
        let session = WorkoutSession(
            id: UUID().uuidString,
            userId: state.profile.id,
            date: sessionDate,
            durationMinutes: nil,
            label: day.title,
            exercises: [Exercise(id: UUID().uuidString, name: exerciseName, exerciseId: exerciseId, exerciseLoadType: exerciseLoadType, sets: [linkedSet])],
            createdAt: now,
            updatedAt: now
        )
        state.strengthSessions.append(session)
        return session.id
    }

    private func actualSetIndex(for planDayId: String, exerciseName: String) -> Int {
        let planDay = state.activePlan.days.first(where: { $0.id == planDayId })
        let date = planDay.flatMap { Self.date(from: $0.planDate) } ?? Date()
        let calendar = Calendar.current

        guard let session = state.strengthSessions.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else {
            return 1
        }
        return (session.exercises.first(where: { $0.name.localizedCaseInsensitiveCompare(exerciseName) == .orderedSame })?.sets.count ?? 0) + 1
    }

    private func normalizeSetIndices(for sessionIndex: Int, exerciseIndex: Int) {
        for index in state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.indices {
            state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[index].setIndex = index + 1
        }
    }

    /// Recomputes `state.profile.stats` / `exercisePRs` if a mutation marked
    /// them stale since the last read. Call before any read path that
    /// exposes derived profile data (`fetchProfile()`, `snapshot()`).
    private func refreshDerivedProfileIfNeeded() {
        guard derivedProfileIsStale else { return }
        recalculateDerivedProfile()
        derivedProfileIsStale = false
    }

    private func recalculateDerivedProfile() {
        let calendar = Calendar.current
        let activeDays = Array(Set((state.strengthSessions.map(\.date) + state.runningRecords.map(\.workoutDate)).map { calendar.startOfDay(for: $0) })).sorted()

        var streak = 0
        var cursor = calendar.startOfDay(for: Date())
        let activeDaySet = Set(activeDays)
        while activeDaySet.contains(cursor) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }

        let totalVolume = state.strengthSessions.reduce(0.0) { partialResult, session in
            partialResult + session.exercises.flatMap(\.sets).reduce(0.0) { subtotal, set in
                // Normalize every set to kilograms before accumulating so that
                // `totalVolumeKg` is correct regardless of each set's display unit.
                let kilograms = (set.weight ?? 0) * set.weightUnit.toKilogramsFactor
                return subtotal + kilograms * Double(set.reps)
            }
        }

        let prsByExercise = makeExercisePRs(from: state.strengthSessions)

        state.profile.exercisePRs = prsByExercise.values.sorted { $0.maxWeightKg > $1.maxWeightKg }
        state.profile.stats = UserStats(
            workoutsCount: state.strengthSessions.count + state.runningRecords.count,
            streakDays: streak,
            totalVolumeKg: totalVolume,
            prCount: state.profile.exercisePRs.count
        )
    }

    // MARK: - Plan edit events

    private struct PlannedSetSnapshot: Encodable {
        let setIndex: Int
        let targetWeight: Double?
        let targetWeightUnit: WeightUnit
        let targetReps: Int

        init(_ set: TrainingPlanSet) {
            setIndex = set.setIndex
            targetWeight = set.targetWeight
            targetWeightUnit = set.targetWeightUnit
            targetReps = set.targetReps
        }
    }

    private struct PlannedExerciseSnapshot: Encodable {
        let exerciseName: String
        let exerciseId: String?
        let exerciseLoadType: ExerciseLoadType
        let sets: [PlannedSetSnapshot]
        let itemType: PlanItemType
        let cardioActivityType: CardioActivityType?
        let targetDurationMinutes: Int?
        let targetDistanceKm: Double?
        let targetRPE: Double?

        init(_ exercise: TrainingPlanExercise) {
            exerciseName = exercise.exerciseName
            exerciseId = exercise.exerciseId
            exerciseLoadType = exercise.exerciseLoadType
            sets = exercise.sets.map(PlannedSetSnapshot.init)
            itemType = exercise.itemType
            cardioActivityType = exercise.cardioActivityType
            targetDurationMinutes = exercise.targetDurationMinutes
            targetDistanceKm = exercise.targetDistanceKm
            targetRPE = exercise.targetRPE
        }
    }

    private struct ExerciseRemovedPayload: Encodable {
        let snapshot: PlannedExerciseSnapshot
        let hadCompletedSets: Bool
    }

    private struct SetRemovedPayload: Encodable {
        let snapshot: PlannedSetSnapshot
        let wasCompleted: Bool
    }

    private struct SetTargetUpdatedPayload: Encodable {
        let before: PlannedSetSnapshot
        let after: PlannedSetSnapshot
    }

    private struct ExercisesReorderedPayload: Encodable {
        let before: [String]
        let after: [String]
    }

    private struct GoalTextChangedPayload: Encodable {
        let before: String?
        let after: String
    }

    private struct GoalSpecChangedPayload: Encodable {
        let before: GoalSpec?
        let after: GoalSpec
    }

    /// Records a structural plan edit. No-op while unarmed (signed out or
    /// DEBUG local mode, EV8) so the outbox never accumulates events nobody
    /// will push. Caps at `maxPendingEditEvents`, dropping the oldest — a
    /// bound against unbounded growth if pushing stays broken for a long
    /// time (EV12), not a limit normal usage should ever reach.
    private func appendEditEvent(
        planId: String? = nil,
        planDayId: String? = nil,
        planDate: String? = nil,
        type: PlanEditEventType,
        exerciseName: String? = nil,
        exerciseId: String? = nil,
        payload: JSONValue
    ) {
        guard let userId = armedUserId else { return }
        state.editEventSeq += 1
        let event = PlanEditEvent(
            id: UUID().uuidString,
            userId: userId,
            planId: planId,
            planDayId: planDayId,
            planDate: planDate,
            eventType: type,
            exerciseName: exerciseName,
            exerciseId: exerciseId,
            payload: payload,
            source: .user,
            clientSeq: state.editEventSeq,
            occurredAt: Date()
        )
        state.pendingEditEvents.append(event)
        let overflow = state.pendingEditEvents.count - Self.maxPendingEditEvents
        if overflow > 0 {
            state.pendingEditEvents.removeFirst(overflow)
            droppedEditEventCount += overflow
        }
    }

    /// Drops events the cloud has confirmed receiving. Safe to call with ids
    /// that no longer exist locally (already cleared by a later call).
    func clearPushedEditEvents(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        state.pendingEditEvents.removeAll { ids.contains($0.id) }
    }

    /// Drops the tombstones the cloud has confirmed deleting. Written straight
    /// to disk (not through `persist`) because this is sync bookkeeping, not a
    /// user mutation: it must not fire `onChange`, advance `localMutationSeq`
    /// or re-derive tombstones from itself.
    ///
    /// Subtracting the confirmed set rather than clearing wholesale keeps a
    /// deletion made *during* the push — which is already tombstoned and still
    /// owed — from being thrown away.
    ///
    /// Throws (rather than swallowing, the way `acknowledgePushedState` does)
    /// when the write fails: the cloud rows are already gone, so a caller that
    /// carried on and acknowledged the push clean would leave a restart
    /// holding tombstones nothing will re-send or retire. Failing the push
    /// instead is safe because the DELETE names its ids — resending it deletes
    /// nothing a second time.
    func clearPushedRecordDeletions(_ confirmed: RecordDeletionLog) throws {
        guard !confirmed.isEmpty else { return }
        let remaining = state.pendingRecordDeletions.removing(confirmed)
        guard remaining != state.pendingRecordDeletions else { return }
        state.pendingRecordDeletions = remaining
        do {
            try writeStateToDisk()
            lastPersistedState = state
        } catch {
            state = lastPersistedState
            throw error
        }
    }

    private func persist() throws {
        guard recoveryStatus == .healthy else { throw LocalAppDatabaseError.recoveryRequired }
        // Mark the outbox dirty in the same atomic write as the mutation
        // itself, so a crash can never persist an edit without also
        // persisting the fact that it still owes the cloud a push. Gated on
        // ownership (not on the push hook): a mutation made after sign-in but
        // before the hook is armed — e.g. while the initial pull is failing
        // offline — must still survive the next cold start's pull.
        if state.ownerUserId != nil {
            state.localMutationSeq += 1
            state.hasUnpushedChanges = true
            // Derive tombstones from the same write. `lastPersistedState` is
            // the pre-mutation baseline (it is what the rollback below
            // restores), so diffing against it names exactly the records this
            // mutation removed — including exercises and sets removed while
            // their session survived. Gated on ownership like the flag above:
            // a deletion made in local-only mode has no cloud counterpart to
            // tombstone. See `RecordDeletionLog`.
            //
            // Both walks are O(records + sets), i.e. the same order as — and
            // far cheaper than — the full-state `JSONEncoder` pass
            // `writeStateToDisk()` runs on the very next line, so this does
            // not reintroduce the per-mutation cost Issue #17 removed.
            state.pendingRecordDeletions = state.pendingRecordDeletions.advanced(
                from: RecordIdentitySet(state: lastPersistedState),
                to: RecordIdentitySet(state: state),
                isSyncable: { $0.isUserGeneratedID }
            )
        }
        do {
            try writeStateToDisk()
            lastPersistedState = state
            onChange?()
        } catch {
            state = lastPersistedState
            throw error
        }
    }

    private func writeStateToDisk() throws {
        try Self.ensureParentDirectoryExists(for: fileURL)
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    // MARK: - Cloud sync bridge

    /// A copy of everything the cloud syncer needs to reconcile. Reads are cheap
    /// (value types), so callers snapshot rather than hold the actor.
    func snapshot() -> LocalDataSnapshot {
        refreshDerivedProfileIfNeeded()
        return LocalDataSnapshot(
            profile: state.profile,
            activePlan: state.activePlan,
            strengthSessions: state.strengthSessions,
            runningRecords: state.runningRecords,
            customExercises: state.customExercises,
            goalSpec: state.goalSpec,
            pendingEditEvents: state.pendingEditEvents,
            mutationSeq: state.localMutationSeq,
            pendingRecordDeletions: state.pendingRecordDeletions
        )
    }

    /// Whether a previous run left local mutations the cloud never confirmed.
    /// Read by `CloudSyncCoordinator.start()` to choose push-first over
    /// pull-first on a cold start.
    func hasUnpushedLocalChanges() -> Bool {
        state.hasUnpushedChanges
    }

    /// Marks the outbox clean — but only if `mutationSeq` still matches, i.e.
    /// no mutation landed after the snapshot the successful push was built
    /// from. Persisted immediately so the flag survives a kill right after
    /// the push. Does not fire `onChange` (this is the sync bookkeeping, not
    /// a user mutation).
    func acknowledgePushedState(mutationSeq: Int64) {
        guard state.hasUnpushedChanges, state.localMutationSeq == mutationSeq else { return }
        state.hasUnpushedChanges = false
        if (try? writeStateToDisk()) != nil {
            lastPersistedState = state
        } else {
            state = lastPersistedState
        }
    }

    func localStateRecoveryStatus() -> LocalStateRecoveryStatus {
        recoveryStatus
    }

    func isCloudSyncSafe() -> Bool {
        recoveryStatus == .healthy
    }

    /// Replace the entire cache with cloud truth. Does not fire `onChange`:
    /// this is the sync writing in, not the user mutating. Derived profile
    /// fields (stats, PRs) are recomputed from the pulled sessions so the UI
    /// matches without a separate stats fetch.
    ///
    /// `pendingEditEvents`/`editEventSeq` are deliberately NOT touched here —
    /// a pull overwrites cloud-mirrored *state*, but those are unpushed
    /// *facts* that must survive it (EV1). `goalSpec` is ordinary state, so
    /// it IS overwritten like everything else, cloud-wins.
    ///
    /// - Note: The login pull path now uses `mergeFromCloud` (which preserves
    ///   real offline user data instead of overwriting it — Issue #1). This
    ///   blunt replace is retained only for any future "force cloud truth"
    ///   scenario; no live caller overwrites offline records with it today.
    func replaceAll(
        profile: UserProfile,
        activePlan: TrainingPlan,
        strengthSessions: [WorkoutSession],
        runningRecords: [RunningWorkoutRecord],
        customExercises: [ExerciseDefinition],
        goalSpec: GoalSpec?
    ) {
        state.profile = profile
        state.activePlan = activePlan
        state.strengthSessions = strengthSessions
        state.runningRecords = runningRecords
        state.customExercises = customExercises
        state.goalSpec = goalSpec
        applyPendingRecordDeletionsToState()
        sanitizePlanCompletionLinks()
        recalculateDerivedProfile()
        if (try? writeStateToDisk()) != nil {
            lastPersistedState = state
        } else {
            state = lastPersistedState
        }
    }

    /// Merge a cloud snapshot into the cache, preserving real offline user
    /// data instead of blindly overwriting it (the bug fixed for Issue #1).
    ///
    /// Policy (see `docs/plans/2026-07-08-cloud-pull-merge-local-plan.md`):
    /// - `strengthSessions` / `runningRecords`: cloud wins; same-id
    ///   collisions resolve by `updatedAt` (tie → cloud); local-only rows
    ///   whose id is a user-generated UUID are kept (offline records
    ///   survive); seed rows (non-UUID id) are dropped so they never reach
    ///   the cloud.
    /// - `customExercises`: cloud wins; local-only user-generated customs
    ///   are kept.
    /// - `activePlan`: cloud structure wins; when `cloud.id == local.id`,
    ///   offline strength-set and cardio completion markers are carried back
    ///   onto the cloud plan
    ///   (completion is monotonic). A local seed plan (different id) is
    ///   replaced wholesale.
    /// - `profile` / `goalSpec`: cloud wins (confirmed decision; timezone
    ///   self-heals via `reconcileDeviceTimezone`).
    /// - `pendingEditEvents` / `editEventSeq`: untouched (EV1).
    ///
    /// Like `replaceAll`, this does NOT fire `onChange`: it is the sync
    /// writing in, not the user mutating, so a pull never echoes back as a
    /// push.
    ///
    /// `remoteDeletions` carries the tombstones a pull read out of the
    /// server-side `record_deletions` log. They are applied *after* the merge,
    /// unconditionally — see `noteRemoteRecordDeletions`. nil means "this merge
    /// did not read the log", which is not the same as "the log was empty":
    /// only a real read may record that the cache is up to date with it.
    func mergeFromCloud(
        profile: UserProfile,
        activePlan: TrainingPlan,
        strengthSessions: [WorkoutSession],
        runningRecords: [RunningWorkoutRecord],
        customExercises: [ExerciseDefinition],
        goalSpec: GoalSpec?,
        remoteDeletions: RemoteRecordDeletions? = nil
    ) {
        let ownerUserId = state.ownerUserId
        state.profile = profile
        state.activePlan = mergePlanPreservingCompletions(cloud: activePlan, local: state.activePlan)
        state.strengthSessions = mergeRecords(
            cloud: strengthSessions.filter { ownerUserId == nil || $0.userId == ownerUserId },
            local: state.strengthSessions.filter { ownerUserId == nil || $0.userId == ownerUserId },
            tombstoned: state.pendingRecordDeletions.sessions
        )
        state.runningRecords = mergeRecords(
            cloud: runningRecords.filter { ownerUserId == nil || $0.userId == ownerUserId },
            local: state.runningRecords.filter { ownerUserId == nil || $0.userId == ownerUserId },
            tombstoned: state.pendingRecordDeletions.runningRecords
        )
        state.customExercises = mergeCustomExercises(cloud: customExercises, local: state.customExercises)
        state.goalSpec = goalSpec
        if let remoteDeletions { noteRemoteRecordDeletions(remoteDeletions) }
        applyPendingRecordDeletionsToState()
        sanitizePlanCompletionLinks()
        // pendingEditEvents / editEventSeq deliberately untouched (EV1).
        recalculateDerivedProfile()
        if (try? writeStateToDisk()) != nil {
            lastPersistedState = state
        } else {
            state = lastPersistedState
        }
    }

    /// The record half of `mergeFromCloud`: folds cloud sessions, cardio
    /// records and custom exercises into the cache and leaves `activePlan`,
    /// `profile` and `goalSpec` exactly as they are.
    ///
    /// This is the merge a device holding *unpushed local edits* can safely
    /// run before pushing (see `CloudSyncCoordinator.performPush`). Record
    /// merging is last-write-wins on `updatedAt` and keeps local-only
    /// user-generated rows, so it cannot revert a local edit — whereas the
    /// cloud-wins halves (plan structure, profile, goal spec) could, which is
    /// why they are excluded here. It used to also be a safety requirement —
    /// the push's full-state `deleteNotIn` would otherwise delete rows another
    /// device added and this cache never saw — but deleting is now driven by
    /// `pendingRecordDeletions` instead (Issue #132), so this merge is about
    /// convergence rather than about keeping the push from destroying data.
    ///
    /// Like `mergeFromCloud`: does NOT fire `onChange`, and (writing through
    /// `writeStateToDisk` rather than `persist`) does not advance
    /// `localMutationSeq` or touch the persisted unpushed-changes flag — the
    /// pending push is still pending, and its acknowledgement must still
    /// match the counter.
    func mergeCloudRecordsPreservingLocalState(
        strengthSessions: [WorkoutSession],
        runningRecords: [RunningWorkoutRecord],
        customExercises: [ExerciseDefinition],
        remoteDeletions: RemoteRecordDeletions? = nil
    ) {
        let ownerUserId = state.ownerUserId
        state.strengthSessions = mergeRecords(
            cloud: strengthSessions.filter { ownerUserId == nil || $0.userId == ownerUserId },
            local: state.strengthSessions.filter { ownerUserId == nil || $0.userId == ownerUserId },
            tombstoned: state.pendingRecordDeletions.sessions
        )
        state.runningRecords = mergeRecords(
            cloud: runningRecords.filter { ownerUserId == nil || $0.userId == ownerUserId },
            local: state.runningRecords.filter { ownerUserId == nil || $0.userId == ownerUserId },
            tombstoned: state.pendingRecordDeletions.runningRecords
        )
        state.customExercises = mergeCustomExercises(cloud: customExercises, local: state.customExercises)
        if let remoteDeletions { noteRemoteRecordDeletions(remoteDeletions) }
        applyPendingRecordDeletionsToState()
        sanitizePlanCompletionLinks()
        recalculateDerivedProfile()
        if (try? writeStateToDisk()) != nil {
            lastPersistedState = state
        } else {
            state = lastPersistedState
        }
    }

    /// Applies one pull's worth of *server* tombstones and advances the cursor.
    ///
    /// Called from inside the merge functions, after the merge and before the
    /// plan-link sanitiser, so the write is atomic with the merge it belongs
    /// to: the cursor can never move without the rows it accounts for being
    /// gone, and a crash mid-pull re-reads the same window rather than skipping
    /// it.
    ///
    /// Unconditional — no `updatedAt` comparison against the local copy. That
    /// is delete-wins (see `RecordDeletionLog`): the tombstone means the row is
    /// gone from the cloud, so a local edit to it has nowhere left to land, and
    /// keeping the row would only mean re-upserting a record the user deleted
    /// on their other device. The direction matters more than the rule: this
    /// drops rows from the *cache*, never from the cloud, so the worst outcome
    /// of a wrong tombstone is a re-pull, while the worst outcome of ignoring a
    /// right one is the deletion silently undone.
    ///
    /// Does not touch `pendingRecordDeletions`: those are *this* device's
    /// unpushed intents. A server tombstone needs no re-sending — the row it
    /// names is already gone from the cloud.
    private func noteRemoteRecordDeletions(_ remote: RemoteRecordDeletions) {
        applyRecordDeletionsToState(remote.log)
        // Advanced only when the read got all the way through (the loader
        // returns nil otherwise), and only forwards: an out-of-order or
        // clock-skewed value must never rewind a cursor past deletions this
        // cache has already accounted for.
        if let newest = remote.newestDeletedAt,
           newest > (state.recordDeletionsSyncedThrough ?? .distantPast) {
            state.recordDeletionsSyncedThrough = newest
        }
        state.recordDeletionsPulledAt = Date()
    }

    /// The cursor for the next incremental read of `record_deletions`, plus
    /// when the last one completed. Read by `CloudSyncCoordinator` before a
    /// pull.
    func recordDeletionSyncState() -> (syncedThrough: Date?, pulledAt: Date?) {
        (state.recordDeletionsSyncedThrough, state.recordDeletionsPulledAt)
    }

    /// Restores the "never upsert and delete the same id in one push"
    /// invariant after a write that bypassed `persist()` — by applying the
    /// pending deletions to the merged state, not by abandoning them.
    ///
    /// `persist()` keeps that invariant for user mutations (see
    /// `RecordDeletionLog.advanced`), but a cloud merge writes straight to
    /// disk, and record merging resolves last-write-wins per *session*: a
    /// session whose cloud copy is newer is adopted whole, which carries back
    /// an exercise or set this device deleted out of it.
    ///
    /// This used to resolve that by dropping the tombstone — update-wins. That
    /// was the local half of Issue #148's gap 3: the same conflict got
    /// update-wins here and delete-wins in the database, whose `ON DELETE
    /// CASCADE` destroys children when a parent goes. Two rules for one
    /// conflict is not a policy, it is a coin flip whose outcome depends on
    /// which side of the sync you ask.
    ///
    /// It is delete-wins now, on both sides. The tombstone stands and the
    /// resurrected rows are stripped back out of the merged state, so the
    /// invariant holds the other way round: the id is neither upserted nor in
    /// conflict, because it is not in the state at all. Note that this only
    /// ever concerns rows *this device's user* deleted — an explicit intent,
    /// arriving after the edit it competes with was already recorded.
    ///
    /// A real un-delete (the user re-creating a record that still carries a
    /// tombstoned id) is unaffected: that goes through `persist()`, where
    /// `advanced` clears the tombstone because the id is present in the state
    /// the user just wrote.
    private func applyPendingRecordDeletionsToState() {
        guard !state.pendingRecordDeletions.isEmpty else { return }
        applyRecordDeletionsToState(state.pendingRecordDeletions)
    }

    /// Removes every row a `RecordDeletionLog` names from the cache, cascading
    /// parent → children exactly as the database does. Used for both the local
    /// pending log and the tombstones a pull read out of `record_deletions`.
    private func applyRecordDeletionsToState(_ deletions: RecordDeletionLog) {
        guard !deletions.isEmpty else { return }
        state.strengthSessions = deletions.applied(toSessions: state.strengthSessions)
        state.runningRecords = deletions.applied(toRunningRecords: state.runningRecords)
        state.customExercises = deletions.applied(toCustomExercises: state.customExercises)
    }

    private func sanitizePlanCompletionLinks() {
        let loggedSetIds = Set(state.strengthSessions.flatMap { session in
            session.exercises.flatMap { exercise in
                exercise.sets.map(\.id)
            }
        })
        let cardioRecordIds = Set(state.runningRecords.map(\.id))

        for dayIndex in state.activePlan.days.indices {
            for exerciseIndex in state.activePlan.days[dayIndex].exercises.indices {
                let exercise = state.activePlan.days[dayIndex].exercises[exerciseIndex]
                if exercise.cardioCompletedAt != nil || exercise.linkedCardioWorkoutId != nil {
                    if let linkedId = exercise.linkedCardioWorkoutId,
                       cardioRecordIds.contains(linkedId) {
                        // The linked record still exists; keep the completion markers.
                    } else {
                        state.activePlan.days[dayIndex].exercises[exerciseIndex].cardioCompletedAt = nil
                        state.activePlan.days[dayIndex].exercises[exerciseIndex].linkedCardioWorkoutId = nil
                    }
                }
                for setIndex in state.activePlan.days[dayIndex].exercises[exerciseIndex].sets.indices {
                    let set = state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex]
                    guard set.completedAt != nil || set.linkedExerciseSetId != nil else { continue }
                    guard let linkedSetId = set.linkedExerciseSetId,
                          loggedSetIds.contains(linkedSetId)
                    else {
                        state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex].completedAt = nil
                        state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex].linkedExerciseSetId = nil
                        continue
                    }
                }
            }
        }
    }

    /// Last-write-wins merge for record lists that carry `updatedAt`. Cloud is
    /// the base; local-only user-generated rows are added (offline records
    /// survive); same-id collisions take the newer `updatedAt` (tie → cloud,
    /// which is already in the dictionary).
    /// Cloud rows carrying an id this device has tombstoned are dropped rather
    /// than merged. Without this a pull landing between the deletion and its
    /// push would put the deleted record back on screen, and the push would
    /// then upsert and delete the same row in one pass. The tombstone is the
    /// newer fact: the cloud copy only still exists because we have not
    /// managed to tell it yet.
    private func mergeRecords<T: CloudMergeableRecord>(
        cloud: [T],
        local: [T],
        tombstoned: Set<String>
    ) -> [T] {
        var byId: [String: T] = [:]
        byId.reserveCapacity(cloud.count)
        for row in cloud where !tombstoned.contains(row.id) { byId[row.id] = row }
        for row in local {
            if let cloudRow = byId[row.id] {
                if row.updatedAt > cloudRow.updatedAt { byId[row.id] = row }
            } else if row.id.isUserGeneratedID {
                byId[row.id] = row
            }
        }
        return Array(byId.values)
    }

    /// Cloud wins; local-only user-generated customs survive.
    /// `ExerciseDefinition` has no timestamps, so no LWW — a same-id
    /// collision keeps cloud.
    private func mergeCustomExercises(cloud: [ExerciseDefinition], local: [ExerciseDefinition]) -> [ExerciseDefinition] {
        let tombstoned = state.pendingRecordDeletions.customExercises
        var byId: [String: ExerciseDefinition] = [:]
        byId.reserveCapacity(cloud.count)
        for exercise in cloud where !tombstoned.contains(exercise.id) { byId[exercise.id] = exercise }
        for exercise in local where byId[exercise.id] == nil && exercise.id.isUserGeneratedID {
            byId[exercise.id] = exercise
        }
        return Array(byId.values)
    }

    /// Cloud plan structure wins. When the same plan id was already present
    /// locally, carry offline plan-set completion markers back onto the cloud
    /// plan (completion is monotonic: once a set is completed it stays
    /// completed). A local seed plan (different id) is replaced wholesale.
    private func mergePlanPreservingCompletions(cloud: TrainingPlan, local: TrainingPlan) -> TrainingPlan {
        guard cloud.id == local.id else { return cloud }

        // Index local completion markers by plan-set id for O(1) lookup.
        var localCompletionById: [String: (completedAt: Date?, linkedExerciseSetId: String?)] = [:]
        var localCardioCompletionById: [String: (completedAt: Date?, linkedCardioWorkoutId: String?)] = [:]
        for day in local.days {
            for exercise in day.exercises {
                if exercise.isCardioCompleted {
                    localCardioCompletionById[exercise.id] = (
                        exercise.cardioCompletedAt,
                        exercise.linkedCardioWorkoutId
                    )
                }
                for set in exercise.sets where set.isCompleted {
                    localCompletionById[set.id] = (set.completedAt, set.linkedExerciseSetId)
                }
            }
        }

        let mergedDays = cloud.days.map { day -> TrainingPlanDay in
            var day = day
            for exerciseIndex in day.exercises.indices {
                if !day.exercises[exerciseIndex].isCardioCompleted,
                   let local = localCardioCompletionById[day.exercises[exerciseIndex].id] {
                    day.exercises[exerciseIndex].cardioCompletedAt = local.completedAt
                    day.exercises[exerciseIndex].linkedCardioWorkoutId = local.linkedCardioWorkoutId
                }
                for setIndex in day.exercises[exerciseIndex].sets.indices {
                    let setId = day.exercises[exerciseIndex].sets[setIndex].id
                    guard !day.exercises[exerciseIndex].sets[setIndex].isCompleted,
                          let local = localCompletionById[setId] else { continue }
                    day.exercises[exerciseIndex].sets[setIndex].completedAt = local.completedAt
                    day.exercises[exerciseIndex].sets[setIndex].linkedExerciseSetId = local.linkedExerciseSetId
                }
            }
            return day
        }

        return TrainingPlan(
            id: cloud.id,
            weekStartDate: cloud.weekStartDate,
            goalSummary: cloud.goalSummary,
            coachSummary: cloud.coachSummary,
            days: mergedDays,
            // Adopt the cloud's revision as the new local baseline — after this
            // merge the local cache reflects the server's (possibly replanned)
            // plan, so the next push's revision guard compares against it.
            revision: cloud.revision
        )
    }

    private static func ensureParentDirectoryExists(for fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private static func backUpUnreadableState(at fileURL: URL) {
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("recovery-\(UUID().uuidString).json")
        try? FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    private static func defaultFileURL() -> URL {
        // On iOS the Application Support lookup always resolves, so this keeps
        // returning the exact same path as before for every real install. The
        // extra temp-directory rung only replaces a force-unwrap that would
        // have crashed the app outright if both container lookups came back
        // empty (sandbox not yet mounted, hostile test host).
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL.appendingPathComponent("PeakLog/peaklog-local-state.json")
    }

    private static func makeSeedState() -> LocalAppState {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today

        // Sample data is user-visible in local mode, so it has to follow the app
        // language like the rest of the UI. Free text uses String(localized:);
        // exercise names are pulled from the library by their stable slug so they
        // stay the single source of truth (and gain a linked mediaId).
        let language = AppLanguage.bestMatch(
            for: Bundle.main.preferredLocalizations + Locale.preferredLanguages
        )
        let library = Dictionary(
            ExerciseSeedLibrary.load().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let plan = TrainingPlan(
            id: "local-plan",
            weekStartDate: planDateString(from: weekStart),
            goalSummary: String(localized: "seed.goal_summary"),
            coachSummary: String(localized: "seed.coach_summary"),
            days: (0..<7).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? today
                let isToday = calendar.isDate(date, inSameDayAs: today)
                return TrainingPlanDay(
                    id: "plan-day-\(offset + 1)",
                    planDate: planDateString(from: date),
                    dayIndex: offset + 1,
                    title: isToday ? String(localized: "seed.day.today_title") : sampleDayTitle(for: offset),
                    focus: sampleDayFocus(for: offset),
                    status: isToday ? "planned" : "upcoming",
                    exercises: samplePlanExercises(for: offset, language: language, library: library)
                )
            }
        )

        let yesterdaySession = WorkoutSession(
            id: "seed-session-1",
            userId: "local-user",
            date: yesterday,
            durationMinutes: 45,
            label: String(localized: "seed.session.pull_day"),
            exercises: [
                Exercise(
                    id: "seed-exercise-1",
                    name: seedExerciseName("deadlift", in: library, language: language),
                    exerciseId: "deadlift",
                    sets: [
                        ExerciseSet(id: "seed-set-1", setIndex: 1, weight: 120, weightUnit: .kg, reps: 5, rpe: nil),
                        ExerciseSet(id: "seed-set-2", setIndex: 2, weight: 120, weightUnit: .kg, reps: 5, rpe: nil)
                    ]
                ),
                Exercise(
                    id: "seed-exercise-2",
                    name: seedExerciseName("pull-up", in: library, language: language),
                    exerciseId: "pull-up",
                    sets: [
                        ExerciseSet(id: "seed-set-3", setIndex: 1, weight: nil, weightUnit: .kg, reps: 10, rpe: nil),
                        ExerciseSet(id: "seed-set-4", setIndex: 2, weight: nil, weightUnit: .kg, reps: 9, rpe: nil)
                    ]
                )
            ],
            createdAt: yesterday.addingTimeInterval(9 * 3600),
            updatedAt: yesterday.addingTimeInterval(9 * 3600)
        )

        let seedRun = RunningWorkoutRecord(
            id: "seed-run-1",
            userId: "local-user",
            workoutDate: calendar.date(byAdding: .day, value: -2, to: today) ?? today,
            durationMinutes: 28,
            distanceKm: 5.2,
            source: .manual,
            createdAt: yesterday,
            updatedAt: yesterday
        )

        var state = LocalAppState(
            profile: UserProfile(
                id: "local-user",
                displayName: String(localized: "seed.profile.display_name"),
                avatarURL: nil,
                membershipLevel: .premium,
                stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: 0, prCount: 0),
                preferences: .defaults(),
                fitnessGoalSummary: String(localized: "seed.goal_summary"),
                exercisePRs: []
            ),
            activePlan: plan,
            strengthSessions: [yesterdaySession],
            runningRecords: [seedRun]
        )

        let db = LocalAppDatabasePreviewDriver(state: state)
        state.profile.stats = db.stats
        state.profile.exercisePRs = db.exercisePRs
        return state
    }

    /// Localized display name for a seed exercise, sourced from the library so
    /// it matches what the picker/detail screens show. Falls back to the slug's
    /// title-cased form only if the library somehow lacks the entry.
    private static func seedExerciseName(
        _ slug: String,
        in library: [String: ExerciseDefinition],
        language: AppLanguage
    ) -> String {
        library[slug]?.displayName(for: language)
            ?? slug.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }

    private static func samplePlanExercises(
        for offset: Int,
        language: AppLanguage,
        library: [String: ExerciseDefinition]
    ) -> [TrainingPlanExercise] {
        func name(_ slug: String) -> String { seedExerciseName(slug, in: library, language: language) }
        switch offset {
        case 0:
            return [
                TrainingPlanExercise(
                    id: "plan-ex-1",
                    orderIndex: 0,
                    exerciseName: name("barbell-bench-press"),
                    exerciseId: "barbell-bench-press",
                    exerciseLoadType: .weighted,
                    progressionMode: "weight_first",
                    notes: String(localized: "seed.note.bench"),
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(id: "plan-set-1", setIndex: 1, targetWeight: 60, targetWeightUnit: .kg, targetReps: 8, completedAt: nil, linkedExerciseSetId: nil),
                        TrainingPlanSet(id: "plan-set-2", setIndex: 2, targetWeight: 60, targetWeightUnit: .kg, targetReps: 8, completedAt: nil, linkedExerciseSetId: nil),
                        TrainingPlanSet(id: "plan-set-3", setIndex: 3, targetWeight: 62.5, targetWeightUnit: .kg, targetReps: 6, completedAt: nil, linkedExerciseSetId: nil)
                    ]
                )
            ]
        case 2:
            return [
                TrainingPlanExercise(
                    id: "plan-ex-2",
                    orderIndex: 0,
                    exerciseName: name("barbell-squat"),
                    exerciseId: "barbell-squat",
                    exerciseLoadType: .weighted,
                    progressionMode: "volume_first",
                    notes: String(localized: "seed.note.squat"),
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(id: "plan-set-4", setIndex: 1, targetWeight: 90, targetWeightUnit: .kg, targetReps: 6, completedAt: nil, linkedExerciseSetId: nil),
                        TrainingPlanSet(id: "plan-set-5", setIndex: 2, targetWeight: 90, targetWeightUnit: .kg, targetReps: 6, completedAt: nil, linkedExerciseSetId: nil)
                    ]
                )
            ]
        case 4:
            return [
                TrainingPlanExercise(
                    id: "plan-ex-3",
                    orderIndex: 0,
                    exerciseName: name("pull-up"),
                    exerciseId: "pull-up",
                    exerciseLoadType: .bodyweight,
                    progressionMode: "rep_first",
                    notes: String(localized: "seed.note.pullup"),
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(id: "plan-set-6", setIndex: 1, targetWeight: nil, targetWeightUnit: .kg, targetReps: 10, completedAt: nil, linkedExerciseSetId: nil),
                        TrainingPlanSet(id: "plan-set-7", setIndex: 2, targetWeight: nil, targetWeightUnit: .kg, targetReps: 10, completedAt: nil, linkedExerciseSetId: nil)
                    ]
                )
            ]
        default:
            return []
        }
    }

    private static func sampleDayTitle(for offset: Int) -> String {
        switch offset {
        case 1: return String(localized: "seed.day_title.recovery")
        case 2: return String(localized: "seed.day_title.lower_strength")
        case 3: return String(localized: "seed.day_title.mobility")
        case 4: return String(localized: "seed.day_title.upper_pull")
        case 5: return String(localized: "seed.day_title.conditioning")
        default: return String(localized: "seed.day_title.rest")
        }
    }

    private static func sampleDayFocus(for offset: Int) -> String? {
        switch offset {
        case 0: return String(localized: "seed.focus.pressing")
        case 1: return String(localized: "seed.focus.aerobic")
        case 2: return String(localized: "seed.focus.leg_drive")
        case 4: return String(localized: "seed.focus.back_volume")
        case 5: return String(localized: "seed.focus.light_conditioning")
        default: return nil
        }
    }

    private static func planDateString(from date: Date) -> String {
        let formatter = WorkoutDateFormatter()
        return formatter.string(from: date)
    }

    private static func date(from planDate: String) -> Date? {
        WorkoutDateFormatter().date(from: planDate)
    }
}

enum LocalAppDatabaseError: LocalizedError {
    case recoveryRequired
    case sessionNotFound
    case exerciseNotFound
    case setNotFound
    case planExerciseNotFound
    case planSetNotFound
    case invalidPlanExerciseName
    case invalidCustomExerciseName
    case invalidExerciseOrder
    case planExerciseNotCardio
    case cardioActivityMismatch
    case cardioAlreadyCompleted

    var errorDescription: String? {
        switch self {
        case .recoveryRequired:
            return "Local data needs recovery before it can be changed."
        case .sessionNotFound:
            return "Workout session not found."
        case .exerciseNotFound:
            return "Exercise not found."
        case .setNotFound:
            return "Set not found."
        case .planExerciseNotFound:
            return "Planned exercise not found."
        case .planSetNotFound:
            return "Planned set not found."
        case .invalidPlanExerciseName:
            return "Exercise name cannot be empty."
        case .invalidCustomExerciseName:
            return "Custom exercise name cannot be empty."
        case .invalidExerciseOrder:
            return "Exercise order is invalid."
        case .planExerciseNotCardio:
            return "The selected plan item is not a cardio activity."
        case .cardioActivityMismatch:
            return "The completed cardio type does not match the plan."
        case .cardioAlreadyCompleted:
            return "This cardio activity is already completed."
        }
    }
}

nonisolated private struct LocalAppDatabasePreviewDriver: Sendable {
    let stats: UserStats
    let exercisePRs: [ExercisePR]

    init(state: LocalAppState) {
        let calendar = Calendar.current
        let activeDays = Array(Set((state.strengthSessions.map(\.date) + state.runningRecords.map(\.workoutDate)).map { calendar.startOfDay(for: $0) })).sorted()
        let totalVolume = state.strengthSessions.reduce(0.0) { partialResult, session in
            partialResult + session.exercises.flatMap(\.sets).reduce(0.0) { subtotal, set in
                // Normalize every set to kilograms before accumulating so that
                // `totalVolumeKg` is correct regardless of each set's display unit.
                let kilograms = (set.weight ?? 0) * set.weightUnit.toKilogramsFactor
                return subtotal + kilograms * Double(set.reps)
            }
        }

        let prsByExercise = makeExercisePRs(from: state.strengthSessions)

        let streak = activeDays.contains(calendar.startOfDay(for: Date())) ? 1 : 0
        self.stats = UserStats(
            workoutsCount: state.strengthSessions.count + state.runningRecords.count,
            streakDays: streak,
            totalVolumeKg: totalVolume,
            prCount: prsByExercise.count
        )
        self.exercisePRs = prsByExercise.values.sorted { $0.maxWeightKg > $1.maxWeightKg }
    }
}

enum AppServices {
    static let database = LocalAppDatabase.shared
    static let profileService: ProfileServiceProtocol = LocalProfileService(database: database)
    static let workoutService: WorkoutServiceProtocol = LocalWorkoutService(database: database)
    static let trainingPlanService: TrainingPlanServiceProtocol = LocalTrainingPlanService(database: database)
    static let exerciseLibraryService: ExerciseLibraryServiceProtocol = LocalExerciseLibraryService(database: database)
    static let setDefaultsProvider: SetDefaultsProviding = RuleBasedSetDefaultsProvider(
        exerciseLibraryService: exerciseLibraryService,
        profileService: profileService
    )
}
