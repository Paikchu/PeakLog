import Foundation

/// Ids of records this device deleted and the cloud has not been told about
/// yet — a client-side tombstone log, one set per cloud table.
///
/// ## Why this exists
///
/// The push used to express deletion as *absence*: it sent the whole local
/// record set and asked the cloud to drop everything not in it. That only
/// means "the user deleted it" if the local cache is known to hold every row
/// the cloud has — which it is not. A row device B added after device A's last
/// read is absent from A's cache for a completely different reason, and A's
/// next push deleted it permanently (Issue #132).
///
/// Absence is not a deletion signal, and no amount of re-reading before the
/// push makes it one: any read has a window after it in which the other device
/// can still insert, and even a read that reaches EOF can miss a row inserted
/// below its cursor mid-scan (see `CloudPagination.fetchAll`). So deletion
/// becomes an explicit, durable *intent* recorded the moment the user deletes
/// something, and the push deletes those ids and nothing else. That removes
/// the race entirely for the destructive direction rather than narrowing it —
/// the push no longer has to reason about rows it has never heard of, because
/// it never asks about them.
///
/// ## Why a diff rather than instrumenting every delete site
///
/// `LocalAppDatabase` deletes records from a dozen domain methods, several of
/// them indirectly (deleting a session takes its exercises and sets with it,
/// editing a workout drops individual sets). Every one of them funnels through
/// `persist()`, so deriving the tombstones there — by diffing the id sets of
/// the state being written against the last persisted one — catches all of
/// them, including nested rows and including ones added later. A per-call-site
/// `recordDeletion(...)` would have to be remembered every time, and forgetting
/// it fails silently and destructively.
///
/// ## The other direction
///
/// This log is the *outbound* half. It tells the cloud that this device deleted
/// a row; on its own it says nothing to the other device, and that gap was
/// Issue #148: after B deleted a record and pushed, A's cached copy survived
/// A's merge and got re-upserted.
///
/// The inbound half is the server-side `record_deletions` table (migration
/// `20260731090000`), written by an `AFTER DELETE` trigger — including rows
/// destroyed by `ON DELETE CASCADE`, which is how a device learns about child
/// rows the deleting device never knew existed. A pull reads it back into a
/// `RecordDeletionLog` (in local id space, via `init(cloudRows:)` below) and
/// applies it to the cache. Neither direction infers anything from absence.
///
/// The convergence rule both halves implement is **delete-wins, per row**: a
/// tombstone for an id beats any update of that id regardless of timestamps.
/// That is not a preference, it is the only rule that can agree with the
/// database — `exercises` and `exercise_sets` are `ON DELETE CASCADE`, so the
/// cloud resolves "one device deleted the session while the other edited a
/// child of it" by destroying the children, and a client that resolved the same
/// conflict by last-write-wins would disagree with the storage it syncs to
/// (Issue #148 gap 3). It is also the only rule that converges without
/// comparing two devices' clocks: a tombstone is monotone — once it exists it
/// stays true — whereas LWW's answer depends on whose clock ran fast.
nonisolated struct RecordDeletionLog: Codable, Sendable, Equatable {
    var sessions: Set<String> = []
    var exercises: Set<String> = []
    var exerciseSets: Set<String> = []
    var runningRecords: Set<String> = []
    var customExercises: Set<String> = []

    var isEmpty: Bool {
        sessions.isEmpty && exercises.isEmpty && exerciseSets.isEmpty
            && runningRecords.isEmpty && customExercises.isEmpty
    }

    /// Folds one local write into the log: ids that vanished become
    /// tombstones, ids that are present become non-tombstones.
    ///
    /// The second half is not symmetry for its own sake — it is the invariant
    /// that keeps the push coherent. A push upserts everything in `after` and
    /// deletes everything in the log; an id in both would be written and then
    /// destroyed in the same push. Re-creating a record with a tombstoned id
    /// (an undo, or a merge folding the row back in) therefore clears the
    /// tombstone.
    ///
    /// - Parameter isSyncable: guards which ids may ever become tombstones.
    ///   Seed rows carry non-UUID ids and were never pushed, so "the seed plan
    ///   got replaced by the real one" must not turn into a DELETE aimed at
    ///   ids the cloud has never seen.
    func advanced(
        from before: RecordIdentitySet,
        to after: RecordIdentitySet,
        isSyncable: (String) -> Bool
    ) -> RecordDeletionLog {
        RecordDeletionLog(
            sessions: Self.step(sessions, before.sessions, after.sessions, isSyncable),
            exercises: Self.step(exercises, before.exercises, after.exercises, isSyncable),
            exerciseSets: Self.step(exerciseSets, before.exerciseSets, after.exerciseSets, isSyncable),
            runningRecords: Self.step(runningRecords, before.runningRecords, after.runningRecords, isSyncable),
            customExercises: Self.step(customExercises, before.customExercises, after.customExercises, isSyncable)
        )
    }

    private static func step(
        _ log: Set<String>,
        _ before: Set<String>,
        _ after: Set<String>,
        _ isSyncable: (String) -> Bool
    ) -> Set<String> {
        log.union(before.subtracting(after).filter(isSyncable)).subtracting(after)
    }

    /// Re-applies the "an id may not be both upserted and deleted" invariant
    /// against a state that was written *without* going through `advanced` —
    /// i.e. a cloud merge.
    ///
    /// `advanced` maintains that invariant for user mutations, but a merge can
    /// also put a tombstoned id back into the state: last-write-wins resolves
    /// per *session*, so a session whose cloud copy is newer is taken whole,
    /// carrying back an exercise or set this device had deleted out of it.
    /// Session-level LWW has by then already ruled that the other device's
    /// edit is the current truth, so the stale deletion intent must go rather
    /// than survive to delete a row the very same push is re-upserting.
    func clearingIdsPresent(in state: RecordIdentitySet) -> RecordDeletionLog {
        RecordDeletionLog(
            sessions: sessions.subtracting(state.sessions),
            exercises: exercises.subtracting(state.exercises),
            exerciseSets: exerciseSets.subtracting(state.exerciseSets),
            runningRecords: runningRecords.subtracting(state.runningRecords),
            customExercises: customExercises.subtracting(state.customExercises)
        )
    }

    /// Drops ids the cloud has confirmed deleted. Idempotent, and deliberately
    /// per-id rather than "clear everything": a delete that raced with a fresh
    /// deletion must not silently discard the new tombstone.
    func removing(_ confirmed: RecordDeletionLog) -> RecordDeletionLog {
        RecordDeletionLog(
            sessions: sessions.subtracting(confirmed.sessions),
            exercises: exercises.subtracting(confirmed.exercises),
            exerciseSets: exerciseSets.subtracting(confirmed.exerciseSets),
            runningRecords: runningRecords.subtracting(confirmed.runningRecords),
            customExercises: customExercises.subtracting(confirmed.customExercises)
        )
    }

    /// The destructive half of a record push, as an explicit ordered list of
    /// "delete exactly these ids from this table".
    ///
    /// Children precede parents so a delete never strands a row mid-request —
    /// the mirror of the upsert half's parents-before-children order.
    ///
    /// - Parameter present: the id set the push is about to upsert. Anything
    ///   in both is dropped from the plan rather than assumed to have been
    ///   cleaned up upstream: the failure this guards against — writing a row
    ///   and destroying it in the same push — is unrecoverable, so it is worth
    ///   re-checking at the point of use.
    /// - Parameter customExerciseCloudId: local custom-exercise ids are
    ///   `custom-<uuid>` while the cloud PK is the bare uuid
    ///   (`CloudMapper.strippedCustomId`). The log is kept in *local* id space
    ///   so it can be matched against merge inputs directly; the translation
    ///   happens here, at the only point that talks to the cloud.
    func deleteTargets(
        excluding present: RecordIdentitySet,
        customExerciseCloudId: (String) -> String = { $0 }
    ) -> [CloudRecordDeleteTarget] {
        let pending = clearingIdsPresent(in: present)
        return [
            Self.target(table: "exercise_sets", ids: pending.exerciseSets) {
                RecordDeletionLog(exerciseSets: $0)
            },
            Self.target(table: "exercises", ids: pending.exercises) {
                RecordDeletionLog(exercises: $0)
            },
            Self.target(table: "workout_sessions", ids: pending.sessions) {
                RecordDeletionLog(sessions: $0)
            },
            Self.target(table: "running_workouts", ids: pending.runningRecords) {
                RecordDeletionLog(runningRecords: $0)
            },
            Self.target(
                table: "custom_exercises",
                ids: pending.customExercises,
                cloudId: customExerciseCloudId
            ) { RecordDeletionLog(customExercises: $0) }
        ].compactMap { $0 }
    }

    private static func target(
        table: String,
        ids: Set<String>,
        cloudId: (String) -> String = { $0 },
        confirmation: (Set<String>) -> RecordDeletionLog
    ) -> CloudRecordDeleteTarget? {
        guard !ids.isEmpty else { return nil }
        // Sorted so a push's request sequence is reproducible instead of
        // following Set's hash order — which matters for reading the deletion
        // audit log back after the fact.
        return CloudRecordDeleteTarget(
            table: table,
            ids: ids.sorted().map(cloudId),
            confirmation: confirmation(ids)
        )
    }
}

// MARK: - Inbound: server tombstones → local cache

extension RecordDeletionLog {
    /// The five tables `record_deletions` may name. Mirrors the CHECK
    /// constraint in migration `20260731090000`; a row naming anything else is
    /// ignored rather than trusted, because the only way one can exist is a
    /// schema change this build has not been taught about.
    static let syncedCloudTables = [
        "workout_sessions", "exercises", "exercise_sets",
        "running_workouts", "custom_exercises"
    ]

    /// Folds one server tombstone in, translating the cloud id into the id
    /// space the local cache uses.
    ///
    /// - Parameter customExerciseLocalId: `custom_exercises` rows are keyed by
    ///   a bare uuid in the cloud and `custom-<uuid>` locally
    ///   (`CloudMapper.localCustomId`) — the mirror of the translation
    ///   `deleteTargets` does on the way out. Kept as a parameter for the same
    ///   reason it is there: this type stays free of the mapper, so it can be
    ///   reasoned about (and tested) without one.
    mutating func insertCloudId(
        _ cloudId: String,
        table: String,
        customExerciseLocalId: (String) -> String = { $0 }
    ) {
        switch table {
        case "workout_sessions": sessions.insert(cloudId)
        case "exercises": exercises.insert(cloudId)
        case "exercise_sets": exerciseSets.insert(cloudId)
        case "running_workouts": runningRecords.insert(cloudId)
        case "custom_exercises": customExercises.insert(customExerciseLocalId(cloudId))
        default: break
        }
    }

    func union(_ other: RecordDeletionLog) -> RecordDeletionLog {
        RecordDeletionLog(
            sessions: sessions.union(other.sessions),
            exercises: exercises.union(other.exercises),
            exerciseSets: exerciseSets.union(other.exerciseSets),
            runningRecords: runningRecords.union(other.runningRecords),
            customExercises: customExercises.union(other.customExercises)
        )
    }

    /// Removes every tombstoned row from a session list, cascading the way the
    /// database does.
    ///
    /// A tombstoned *session* takes its whole subtree with it, which is exactly
    /// what `ON DELETE CASCADE` did on the server side; a tombstoned exercise
    /// or set is stripped out of a session that survives. Both directions are
    /// unconditional — no `updatedAt` comparison — because that is what
    /// delete-wins means: the session's cloud copy being newer says the other
    /// device edited the session, not that it un-deleted this row.
    ///
    /// A session left with no exercises is deliberately **kept**. Emptiness is
    /// not a deletion signal here any more than absence is anywhere else: the
    /// session row is still in the cloud (it has no tombstone), so dropping it
    /// locally would just make the next pull bring it back. When the user
    /// really deletes the last exercise, `LocalAppDatabase.deleteExercise`
    /// removes the session too and the push tombstones it, so a genuine
    /// deletion always arrives here as a session tombstone.
    func applied(toSessions sessions: [WorkoutSession]) -> [WorkoutSession] {
        guard !self.sessions.isEmpty || !exercises.isEmpty || !exerciseSets.isEmpty else {
            return sessions
        }
        var result: [WorkoutSession] = []
        result.reserveCapacity(sessions.count)
        for var session in sessions where !self.sessions.contains(session.id) {
            session.exercises.removeAll { exercises.contains($0.id) }
            if !exerciseSets.isEmpty {
                for index in session.exercises.indices {
                    session.exercises[index].sets.removeAll { exerciseSets.contains($0.id) }
                }
            }
            result.append(session)
        }
        return result
    }

    func applied(toRunningRecords records: [RunningWorkoutRecord]) -> [RunningWorkoutRecord] {
        guard !runningRecords.isEmpty else { return records }
        return records.filter { !runningRecords.contains($0.id) }
    }

    func applied(toCustomExercises definitions: [ExerciseDefinition]) -> [ExerciseDefinition] {
        guard !customExercises.isEmpty else { return definitions }
        return definitions.filter { !customExercises.contains($0.id) }
    }
}

/// One pull's worth of server tombstones, plus the cursor for the next pull.
///
/// `newestDeletedAt` is a **server** timestamp, read back out of the rows —
/// never a device clock. That is what keeps a device whose clock is wrong from
/// advancing its cursor past a deletion it has not seen.
nonisolated struct RemoteRecordDeletions: Sendable, Equatable {
    var log = RecordDeletionLog()
    var newestDeletedAt: Date?

    var isEmpty: Bool { log.isEmpty }

    /// How far back a pull re-reads before its stored cursor.
    ///
    /// `deleted_at` defaults to `now()`, which Postgres evaluates when the
    /// deleting statement runs — not when it commits. A transaction that
    /// commits after our read started, but stamped a `deleted_at` before it,
    /// would be invisible to a strict `> cursor` scan and never seen again. So
    /// the scan is `>= cursor - overlap`, and applying a tombstone twice is a
    /// no-op (the row is already gone; ids are fresh UUIDs and are never
    /// reused), which makes the overlap free apart from bytes.
    ///
    /// One hour is far beyond any commit latency a phone's single-row DELETE
    /// can produce, and small enough that a daily user re-reads a handful of
    /// rows rather than the retention window.
    static let cursorOverlap: TimeInterval = 3600
}

/// One table's share of a tombstone push.
///
/// `ids` are **cloud** ids (what the DELETE names); `confirmation` is the same
/// rows as a log in **local** id space, so the caller can retire exactly this
/// batch of tombstones the instant its request lands — before attempting the
/// next table. A push that dies on its third table must not lose the fact that
/// the first two are already done.
nonisolated struct CloudRecordDeleteTarget: Sendable, Equatable {
    let table: String
    let ids: [String]
    let confirmation: RecordDeletionLog
}

/// The id set of one local state, keyed the way the cloud tables are — the
/// input `RecordDeletionLog.advanced(from:to:)` diffs and `deleteTargets`
/// subtracts.
///
/// Only the five tables that carry user *records* are tracked. The plan child
/// tables are excluded on purpose: the cache holds the active plan in full and
/// the server bumps `revision` when it replans, so a scoped absence-prune plus
/// the revision guard is the protocol there — see
/// `CloudSyncCoordinator.performPush`.
nonisolated struct RecordIdentitySet: Sendable, Equatable {
    var sessions: Set<String> = []
    var exercises: Set<String> = []
    var exerciseSets: Set<String> = []
    var runningRecords: Set<String> = []
    var customExercises: Set<String> = []

    init() {}

    /// Walks the session nesting so a deleted exercise or set is tombstoned
    /// even when its parent session survives — the common case when a user
    /// edits a logged workout rather than deleting it.
    init(
        strengthSessions: [WorkoutSession],
        runningRecords: [RunningWorkoutRecord],
        customExercises: [ExerciseDefinition]
    ) {
        for session in strengthSessions {
            sessions.insert(session.id)
            for exercise in session.exercises {
                exercises.insert(exercise.id)
                for set in exercise.sets {
                    exerciseSets.insert(set.id)
                }
            }
        }
        self.runningRecords = Set(runningRecords.map(\.id))
        self.customExercises = Set(customExercises.map(\.id))
    }

    /// The record ids a push is about to upsert.
    init(snapshot: LocalDataSnapshot) {
        self.init(
            strengthSessions: snapshot.strengthSessions,
            runningRecords: snapshot.runningRecords,
            customExercises: snapshot.customExercises
        )
    }
}
