import Foundation

// Logic test for the Issue #132 fix: a push must delete only the records the
// user actually deleted, never the records it merely has not heard of.
//
// Two `LocalAppDatabase` instances stand in for devices A and B, wired to one
// in-memory "cloud" through the real production seams — `CloudMapper.pushBundle`
// on the way out, `CloudMapper.assembleSnapshot` +
// `mergeCloudRecordsPreservingLocalState` on the way in — so the only thing the
// harness itself decides is *which delete protocol the push uses*:
//
//   .tombstones     the fix: DELETE exactly `pendingRecordDeletions`
//   .absencePrune   what shipped before: DELETE everything the local snapshot
//                   does not contain
//
// Keeping the old protocol in the harness is what stops this test from passing
// vacuously: every scenario that asserts "B's row survived A's stale push" also
// asserts that the same scenario *destroys* it under `.absencePrune`. If the
// fixture ever stopped reproducing the race, both halves would fail.
//
// Coverage:
//   1. A's stale push does not delete rows B added — across all five record
//      tables (workout_sessions, exercises, exercise_sets, running_workouts,
//      custom_exercises) — and the same push under the old protocol does.
//   2. Interleaved updates converge by last-write-wins on `updatedAt` without
//      either device's push deleting the other's rows.
//   3. A deletion pushes exactly its own ids: siblings and B's additions live.
//   4. A pull landing between the delete and its push does not resurrect the
//      record, locally or in the cloud.
//   5. A deletion survives a failed push and a process restart (the tombstone
//      is persisted, not in-memory).
//   6. Deleting one exercise out of a surviving session tombstones that
//      exercise and its sets, and nothing else.
//   7. When last-write-wins hands the session back with the deleted exercise
//      still in it, the stale tombstone is dropped — a push never upserts and
//      deletes the same id.
//   8. running_workouts / custom_exercises tombstones, including the
//      `custom-<uuid>` → bare-uuid translation the cloud PK needs, and the
//      seed-id guard that keeps never-pushed rows out of the DELETE.
//   9. a push carrying no prune at all still delivers the deletion, and a
//      failed DELETE leaves the intent pending instead of acknowledging it
//      away (Codex P2 on #141: a skipped prune used to undo the user's
//      deletion silently, because absence was the only delete channel).
//
// Compile with:
//   swiftc -parse-as-library \
//     PeakLog/Models/*.swift PeakLog/Localization/AppLanguage.swift \
//     PeakLog/Support/WorkoutDateFormatter.swift \
//     PeakLog/Services/ProfileService.swift PeakLog/Services/WorkoutService.swift \
//     PeakLog/Services/TrainingPlanService.swift PeakLog/Services/ExerciseLibraryService.swift \
//     PeakLog/Services/ExerciseRecommendationEngine.swift PeakLog/Services/SetDefaultsProvider.swift \
//     PeakLog/Services/LocalAppDatabase.swift \
//     PeakLog/Services/Cloud/LocalDataSnapshot.swift \
//     PeakLog/Services/Cloud/RecordDeletionLog.swift \
//     PeakLog/Services/Cloud/CloudRows.swift PeakLog/Services/Cloud/CloudMapper.swift \
//     tests/cloud_record_deletion_sync_test.swift -o /tmp/crd && /tmp/crd

@main
struct CloudRecordDeletionSyncTest {
    static let userId = "5a1b0f9e-1c2d-4e3f-8a9b-0c1d2e3f4a5b"

    static func main() async throws {
        try await testStalePushKeepsOtherDeviceAdditions()
        try await testAbsencePruneStillDestroysThem()
        try await testInterleavedUpdatesConverge()
        try await testDeletionPushesOnlyItsOwnIds()
        try await testPullBetweenDeleteAndPushDoesNotResurrect()
        try await testDeletionSurvivesFailedPushAndRestart()
        try await testExerciseDeletionInsideSurvivingSession()
        try await testLastWriteWinsResurrectionDropsTheTombstone()
        try await testSkippedPruneCannotSilentlyUndoADeletion()
        try await testFailedDeleteKeepsTheIntentPending()
        testRunningAndCustomExerciseTombstones()
        print("cloud_record_deletion_sync_test passed")
    }

    // MARK: - 1: the headline — A's stale push must not delete B's rows

    /// Device B adds one row in each of the five record tables while device A
    /// is away; A then edits something locally and pushes without pulling.
    /// Under the old protocol A's snapshot — which has never seen any of B's
    /// rows — was the authority for deleting, and every one of them went.
    static func testStalePushKeepsOtherDeviceAdditions() async throws {
        let world = try await interleavedWorld(protocol: .tombstones)

        expect(world.cloud.sessions[world.sessionB] != nil, "B's session was deleted by A's stale push")
        expect(world.cloud.exercises[world.exerciseB] != nil, "B's exercise was deleted by A's stale push")
        expect(world.cloud.sets[world.setB] != nil, "B's set was deleted by A's stale push")
        expect(world.cloud.running[world.runningB] != nil, "B's cardio record was deleted by A's stale push")
        expect(world.cloud.customs[world.customB] != nil, "B's custom exercise was deleted by A's stale push")
        // B also appended a set to a session A already knew about: the nested
        // case, where the parent row IS in A's snapshot and only the child is
        // new. An absence prune scoped per table cannot tell those apart.
        expect(world.cloud.sets[world.setAddedByBToASession] != nil,
               "B's set on A's session was deleted by A's stale push")
        // A's own rows are still there — the fix must not have simply disabled
        // the push.
        expect(world.cloud.sessions[world.sessionA] != nil, "A's own session went missing")
        expect(world.cloud.sets[world.setAddedByA] != nil, "A's own new set was never pushed")
    }

    /// The same fixture under the protocol that shipped before, so the test
    /// cannot pass just because the scenario stopped reproducing the race.
    static func testAbsencePruneStillDestroysThem() async throws {
        let world = try await interleavedWorld(protocol: .absencePrune)

        expect(world.cloud.sessions[world.sessionB] == nil, "fixture no longer reproduces Issue #132")
        expect(world.cloud.exercises[world.exerciseB] == nil, "fixture no longer reproduces Issue #132")
        expect(world.cloud.sets[world.setB] == nil, "fixture no longer reproduces Issue #132")
        expect(world.cloud.running[world.runningB] == nil, "fixture no longer reproduces Issue #132")
        expect(world.cloud.customs[world.customB] == nil, "fixture no longer reproduces Issue #132")
        expect(world.cloud.sets[world.setAddedByBToASession] == nil, "fixture no longer reproduces Issue #132")
    }

    struct InterleavedWorld {
        let cloud: StubCloud
        let sessionA: String
        let setAddedByA: String
        let sessionB: String
        let exerciseB: String
        let setB: String
        let runningB: String
        let customB: String
        let setAddedByBToASession: String
    }

    static func interleavedWorld(protocol proto: PushProtocol) async throws -> InterleavedWorld {
        let cloud = StubCloud()
        let deviceA = await makeDevice()
        let deviceB = await makeDevice()

        // 1. A logs a workout and pushes; B pulls it.
        let sessionA = try await deviceA.createStrengthSession(draft(title: "A day 1"))
        try await push(deviceA, to: cloud, using: proto)
        await pull(deviceB, from: cloud)

        // 2. B adds one row per record table, plus a set on A's session.
        let sessionB = try await deviceB.createStrengthSession(draft(title: "B day 1"))
        let runningB = try await deviceB.createRunningRecord(
            workoutDate: Date(), durationMinutes: 30, distanceKm: 5, source: .manual
        )
        let customB = try await deviceB.addCustomExercise(
            name: "Zercher Squat", muscleGroup: .legs, loadType: .weighted
        )
        let setOnASession = try await deviceB.addSet(
            sessionId: sessionA.id,
            exerciseId: sessionA.exercises[0].id,
            weight: 60, weightUnit: .kg, reps: 5
        )
        try await push(deviceB, to: cloud, using: proto)

        // 3. A never pulls — it just edits its own workout and pushes. This is
        //    the exact sequence from the issue's repro steps.
        let setByA = try await deviceA.addSet(
            sessionId: sessionA.id,
            exerciseId: sessionA.exercises[0].id,
            weight: 80, weightUnit: .kg, reps: 3
        )
        try await push(deviceA, to: cloud, using: proto)

        return InterleavedWorld(
            cloud: cloud,
            sessionA: sessionA.id,
            setAddedByA: setByA.id,
            sessionB: sessionB.id,
            exerciseB: sessionB.exercises[0].id,
            setB: sessionB.exercises[0].sets[0].id,
            runningB: runningB.id,
            customB: CloudMapper.strippedCustomId(customB.id),
            setAddedByBToASession: setOnASession.id
        )
    }

    // MARK: - 2: interleaved updates

    /// Both devices edit rows the other one owns, alternating pushes and
    /// pulls. Nothing may be destroyed, and the shared row must settle on the
    /// later `updatedAt`.
    static func testInterleavedUpdatesConverge() async throws {
        let cloud = StubCloud()
        let deviceA = await makeDevice()
        let deviceB = await makeDevice()

        let sessionA = try await deviceA.createStrengthSession(draft(title: "shared"))
        try await push(deviceA, to: cloud, using: .tombstones)
        await pull(deviceB, from: cloud)

        // A edits first, B edits second — B's write is the newer one.
        _ = try await deviceA.updateSet(
            sessionId: sessionA.id,
            exerciseId: sessionA.exercises[0].id,
            setId: sessionA.exercises[0].sets[0].id,
            weight: 100, weightUnit: .kg, reps: 5
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await deviceB.updateSet(
            sessionId: sessionA.id,
            exerciseId: sessionA.exercises[0].id,
            setId: sessionA.exercises[0].sets[0].id,
            weight: 120, weightUnit: .kg, reps: 5
        )

        try await push(deviceA, to: cloud, using: .tombstones)
        try await push(deviceB, to: cloud, using: .tombstones)
        await pull(deviceA, from: cloud)

        let finalA = await deviceA.snapshot()
        let weight = finalA.strengthSessions
            .first { $0.id == sessionA.id }?
            .exercises.first?.sets.first?.weight
        expect(weight == 120, "later write should win, got \(String(describing: weight))")
        expect(cloud.sessions.count == 1, "an update must not create or destroy sessions")
        expect(finalA.pendingRecordDeletions.isEmpty, "an update must not produce a tombstone")
    }

    // MARK: - 3: a deletion pushes exactly its own ids

    static func testDeletionPushesOnlyItsOwnIds() async throws {
        let cloud = StubCloud()
        let deviceA = await makeDevice()
        let deviceB = await makeDevice()

        let doomed = try await deviceA.createStrengthSession(draft(title: "to delete"))
        let keeper = try await deviceA.createStrengthSession(draft(title: "to keep"))
        try await push(deviceA, to: cloud, using: .tombstones)
        await pull(deviceB, from: cloud)

        // B adds a session A will never see before A's next push.
        let sessionB = try await deviceB.createStrengthSession(draft(title: "B only"))
        try await push(deviceB, to: cloud, using: .tombstones)

        // Deleting a session's only exercise removes the session with it.
        try await deviceA.deleteExercise(sessionId: doomed.id, exerciseId: doomed.exercises[0].id)
        let pending = await deviceA.snapshot().pendingRecordDeletions
        expect(pending.sessions == [doomed.id], "session tombstone missing or over-broad: \(pending.sessions)")
        expect(pending.exercises == [doomed.exercises[0].id], "exercise tombstone wrong: \(pending.exercises)")
        expect(pending.exerciseSets == [doomed.exercises[0].sets[0].id], "set tombstone wrong: \(pending.exerciseSets)")

        try await push(deviceA, to: cloud, using: .tombstones)

        expect(cloud.sessions[doomed.id] == nil, "the deleted session survived the push")
        expect(cloud.exercises[doomed.exercises[0].id] == nil, "the deleted exercise survived the push")
        expect(cloud.sets[doomed.exercises[0].sets[0].id] == nil, "the deleted set survived the push")
        expect(cloud.sessions[keeper.id] != nil, "a sibling session was destroyed by the delete")
        expect(cloud.sessions[sessionB.id] != nil, "B's session was destroyed by A's delete push")

        let cleared = await deviceA.snapshot().pendingRecordDeletions
        expect(cleared.isEmpty, "confirmed tombstones must be retired, still holds \(cleared)")
    }

    // MARK: - 4: a pull may not resurrect a pending deletion

    static func testPullBetweenDeleteAndPushDoesNotResurrect() async throws {
        let cloud = StubCloud()
        let deviceA = await makeDevice()

        let doomed = try await deviceA.createStrengthSession(draft(title: "to delete"))
        try await push(deviceA, to: cloud, using: .tombstones)

        try await deviceA.deleteExercise(sessionId: doomed.id, exerciseId: doomed.exercises[0].id)
        // The cloud still holds the row — we have not managed to tell it yet.
        expect(cloud.sessions[doomed.id] != nil, "fixture: the cloud should still hold the row here")
        await pull(deviceA, from: cloud)

        let afterPull = await deviceA.snapshot()
        expect(!afterPull.strengthSessions.contains { $0.id == doomed.id },
               "a pull put the deleted session back on screen")
        expect(afterPull.pendingRecordDeletions.sessions == [doomed.id],
               "the pull dropped the pending deletion")

        try await push(deviceA, to: cloud, using: .tombstones)
        expect(cloud.sessions[doomed.id] == nil, "the deletion never reached the cloud")
    }

    // MARK: - 5: the tombstone is durable

    static func testDeletionSurvivesFailedPushAndRestart() async throws {
        let cloud = StubCloud()
        let fileURL = tempURL()
        let deviceA = await makeDevice(fileURL: fileURL)

        let doomed = try await deviceA.createStrengthSession(draft(title: "to delete"))
        try await push(deviceA, to: cloud, using: .tombstones)
        try await deviceA.deleteExercise(sessionId: doomed.id, exerciseId: doomed.exercises[0].id)
        // No push here: the device was killed, or the network was down.

        let restarted = LocalAppDatabase(fileURL: fileURL)
        let recovered = await restarted.snapshot()
        expect(recovered.pendingRecordDeletions.sessions == [doomed.id],
               "the tombstone did not survive the restart: \(recovered.pendingRecordDeletions)")
        expect(await restarted.hasUnpushedLocalChanges(), "the outbox flag did not survive the restart")

        try await push(restarted, to: cloud, using: .tombstones)
        expect(cloud.sessions[doomed.id] == nil, "the recovered deletion never reached the cloud")
    }

    // MARK: - 6: deleting a child of a surviving parent

    static func testExerciseDeletionInsideSurvivingSession() async throws {
        let cloud = StubCloud()
        let deviceA = await makeDevice()

        let session = try await deviceA.createStrengthSession(
            StrengthSessionDraft(
                title: "two exercises",
                workoutDate: Date(),
                exercises: [exerciseDraft(name: "Bench"), exerciseDraft(name: "Row")]
            )
        )
        try await push(deviceA, to: cloud, using: .tombstones)

        let removed = session.exercises[1]
        let kept = session.exercises[0]
        try await deviceA.deleteExercise(sessionId: session.id, exerciseId: removed.id)

        let pending = await deviceA.snapshot().pendingRecordDeletions
        expect(pending.sessions.isEmpty, "the surviving session must not be tombstoned")
        expect(pending.exercises == [removed.id], "wrong exercise tombstoned: \(pending.exercises)")
        expect(pending.exerciseSets == Set(removed.sets.map(\.id)), "the removed exercise's sets were not tombstoned")

        try await push(deviceA, to: cloud, using: .tombstones)
        expect(cloud.sessions[session.id] != nil, "the surviving session was deleted")
        expect(cloud.exercises[kept.id] != nil, "the surviving exercise was deleted")
        expect(cloud.exercises[removed.id] == nil, "the deleted exercise survived")
        expect(cloud.sets[removed.sets[0].id] == nil, "the deleted exercise's set survived")
    }

    // MARK: - 7: LWW may cancel a deletion; the tombstone must go with it

    /// A deletes an exercise out of a session; B edits the same session
    /// afterwards, so B's copy is the newer one. When A pulls, last-write-wins
    /// hands the session back whole — deleted exercise included. The stale
    /// tombstone has to be dropped, or A's next push would upsert that
    /// exercise and then delete it in the same pass.
    static func testLastWriteWinsResurrectionDropsTheTombstone() async throws {
        let cloud = StubCloud()
        let deviceA = await makeDevice()
        let deviceB = await makeDevice()

        let session = try await deviceA.createStrengthSession(
            StrengthSessionDraft(
                title: "contested",
                workoutDate: Date(),
                exercises: [exerciseDraft(name: "Bench"), exerciseDraft(name: "Row")]
            )
        )
        try await push(deviceA, to: cloud, using: .tombstones)
        await pull(deviceB, from: cloud)

        let contested = session.exercises[1]
        try await deviceA.deleteExercise(sessionId: session.id, exerciseId: contested.id)
        try await Task.sleep(nanoseconds: 5_000_000)
        // B's edit lands later, so B's copy of the session wins LWW.
        _ = try await deviceB.addSet(
            sessionId: session.id,
            exerciseId: session.exercises[0].id,
            weight: 70, weightUnit: .kg, reps: 8
        )
        try await push(deviceB, to: cloud, using: .tombstones)

        await pull(deviceA, from: cloud)
        let merged = await deviceA.snapshot()
        let mergedSession = merged.strengthSessions.first { $0.id == session.id }
        expect(mergedSession?.exercises.contains { $0.id == contested.id } == true,
               "fixture: LWW should have handed the contested exercise back")
        expect(merged.pendingRecordDeletions.exercises.isEmpty,
               "a resurrected id must not stay tombstoned: \(merged.pendingRecordDeletions.exercises)")

        try await push(deviceA, to: cloud, using: .tombstones)
        expect(cloud.exercises[contested.id] != nil,
               "the push upserted the exercise and then deleted it in the same pass")
    }

    // MARK: - 9: a skipped prune cannot silently undo a deletion

    /// Codex's P2 on #141. Before this change, a deletion travelled as the
    /// *absence* of a row from the pushed snapshot, so it only reached the
    /// cloud if the prune ran. When the prune was skipped — an incomplete
    /// cloud read disables it — `performPush` still ran to completion and
    /// acknowledged, clearing the persisted "owes a push" flag. The cloud row
    /// survived, the next pull merged it back, and the user's deletion was
    /// silently undone with nothing left to retry from.
    ///
    /// The tombstone decouples the two: deletion is its own durable intent, it
    /// is never gated on the prune, and it is retired only by the cloud
    /// confirming the DELETE. Acknowledging the push is then harmless.
    static func testSkippedPruneCannotSilentlyUndoADeletion() async throws {
        let cloud = StubCloud()
        let deviceA = await makeDevice()

        let doomed = try await deviceA.createStrengthSession(draft(title: "to delete"))
        try await push(deviceA, to: cloud, using: .tombstones)
        try await deviceA.deleteExercise(sessionId: doomed.id, exerciseId: doomed.exercises[0].id)

        // This push carries no prune at all — the record half is all there is,
        // which is exactly the situation an incomplete cloud read produces.
        try await push(deviceA, to: cloud, using: .tombstones)

        expect(cloud.sessions[doomed.id] == nil, "the deletion did not survive a push with no prune")
        expect(!(await deviceA.hasUnpushedLocalChanges()), "a fully delivered push should acknowledge")

        // And a pull now has nothing to restore it from.
        await pull(deviceA, from: cloud)
        let after = await deviceA.snapshot()
        expect(!after.strengthSessions.contains { $0.id == doomed.id }, "the pull resurrected the deleted session")
    }

    /// The other half: if the DELETE itself fails, the intent must outlive the
    /// push rather than be acknowledged away.
    static func testFailedDeleteKeepsTheIntentPending() async throws {
        let cloud = StubCloud()
        let deviceA = await makeDevice()

        let doomed = try await deviceA.createStrengthSession(draft(title: "to delete"))
        try await push(deviceA, to: cloud, using: .tombstones)
        try await deviceA.deleteExercise(sessionId: doomed.id, exerciseId: doomed.exercises[0].id)

        do {
            try await push(deviceA, to: cloud, using: .tombstones, deletesFail: true)
            expect(false, "the fixture should have failed the DELETE")
        } catch StubCloudError.network {
        }

        let pending = await deviceA.snapshot()
        expect(pending.pendingRecordDeletions.sessions == [doomed.id],
               "a failed DELETE dropped the tombstone: \(pending.pendingRecordDeletions)")
        expect(await deviceA.hasUnpushedLocalChanges(), "a failed push must stay dirty")
        expect(cloud.sessions[doomed.id] != nil, "fixture: the cloud row should still be there")

        try await push(deviceA, to: cloud, using: .tombstones)
        expect(cloud.sessions[doomed.id] == nil, "the retry did not deliver the deletion")
    }

    // MARK: - 8: running / custom exercise tombstones (pure)

    /// `LocalAppDatabase` has no delete path for cardio records or custom
    /// exercises today — which is exactly why the old absence prune was pure
    /// downside for those two tables: it could never express a real deletion,
    /// only destroy rows the device had not seen. The tombstone plumbing for
    /// them is covered here at the level it exists at.
    static func testRunningAndCustomExerciseTombstones() {
        let keptRun = cardioRecord(id: UUID().uuidString)
        let deletedRun = cardioRecord(id: UUID().uuidString)
        let keptCustom = customExercise(id: "custom-\(UUID().uuidString.lowercased())")
        let deletedCustom = customExercise(id: "custom-\(UUID().uuidString.lowercased())")
        // A seed row: non-UUID id, never pushed, must never become a DELETE.
        let seedCustom = customExercise(id: "seed-bench-press")

        let before = RecordIdentitySet(
            strengthSessions: [],
            runningRecords: [keptRun, deletedRun],
            customExercises: [keptCustom, deletedCustom, seedCustom]
        )
        let after = RecordIdentitySet(
            strengthSessions: [],
            runningRecords: [keptRun],
            customExercises: [keptCustom]
        )
        let log = RecordDeletionLog().advanced(from: before, to: after, isSyncable: isUserGenerated)

        expect(log.runningRecords == [deletedRun.id], "cardio tombstone wrong: \(log.runningRecords)")
        expect(log.customExercises == [deletedCustom.id], "custom tombstone wrong: \(log.customExercises)")

        let targets = log.deleteTargets(
            excluding: after,
            customExerciseCloudId: CloudMapper.strippedCustomId
        )
        let byTable = Dictionary(uniqueKeysWithValues: targets.map { ($0.table, $0) })
        expect(byTable["running_workouts"]?.ids == [deletedRun.id], "cardio delete target wrong")
        expect(byTable["custom_exercises"]?.ids == [CloudMapper.strippedCustomId(deletedCustom.id)],
               "custom delete target must use the bare cloud uuid, got \(byTable["custom_exercises"]?.ids ?? [])")
        expect(byTable["custom_exercises"]?.confirmation.customExercises == [deletedCustom.id],
               "the confirmation must stay in local id space so the tombstone can be retired")
        expect(targets.map(\.table) == ["running_workouts", "custom_exercises"],
               "children must precede parents: \(targets.map(\.table))")

        // An id the push is about to upsert is never also deleted, even if a
        // stale tombstone names it.
        var stale = log
        stale.runningRecords.insert(keptRun.id)
        let guarded = stale.deleteTargets(excluding: after)
        expect(guarded.first { $0.table == "running_workouts" }?.ids == [deletedRun.id],
               "deleteTargets must drop ids the same push is upserting")
    }

    // MARK: - harness

    enum PushProtocol {
        /// The fix: DELETE only what the tombstone log names.
        case tombstones
        /// What shipped before Issue #132: DELETE everything absent from the
        /// pushing device's snapshot.
        case absencePrune
    }

    /// Mirrors `CloudSyncCoordinator.performPush`'s record half: upsert the
    /// whole bundle, then reconcile deletions by the chosen protocol, then
    /// acknowledge.
    ///
    /// - Parameter deletesFail: models the network dying on the DELETE. The
    ///   real `performPush` throws out of `deleteTombstonedRecords`, so
    ///   `acknowledgePushedState` is never reached — reproduced here, because
    ///   the whole point of a tombstone is that a failed push keeps it.
    static func push(
        _ database: LocalAppDatabase,
        to cloud: StubCloud,
        using proto: PushProtocol,
        deletesFail: Bool = false
    ) async throws {
        let snapshot = await database.snapshot()
        let bundle = try CloudMapper.pushBundle(from: snapshot, userId: userId)

        for row in bundle.customExercises { cloud.customs[row.id] = row }
        for row in bundle.sessions { cloud.sessions[row.id] = row }
        for row in bundle.exercises { cloud.exercises[row.id] = row }
        for row in bundle.exerciseSets { cloud.sets[row.id] = row }
        for row in bundle.running { cloud.running[row.id] = row }

        switch proto {
        case .absencePrune:
            cloud.keepOnly(
                sessions: Set(bundle.sessions.map(\.id)),
                exercises: Set(bundle.exercises.map(\.id)),
                sets: Set(bundle.exerciseSets.map(\.id)),
                running: Set(bundle.running.map(\.id)),
                customs: Set(bundle.customExercises.map(\.id))
            )
        case .tombstones:
            let targets = snapshot.pendingRecordDeletions.deleteTargets(
                excluding: RecordIdentitySet(snapshot: snapshot),
                customExerciseCloudId: CloudMapper.strippedCustomId
            )
            for target in targets {
                if deletesFail { throw StubCloudError.network }
                cloud.delete(table: target.table, ids: target.ids)
                await database.clearPushedRecordDeletions(target.confirmation)
            }
        }

        await database.acknowledgePushedState(mutationSeq: snapshot.mutationSeq)
    }

    /// Mirrors the record half of `CloudSyncCoordinator.pull`.
    static func pull(_ database: LocalAppDatabase, from cloud: StubCloud) async {
        let data = CloudMapper.assembleSnapshot(
            userId: userId,
            profileRow: nil,
            preferencesRow: nil,
            goalSpecRow: nil,
            customRows: Array(cloud.customs.values),
            sessionRows: Array(cloud.sessions.values),
            exerciseRows: Array(cloud.exercises.values),
            setRows: Array(cloud.sets.values),
            runningRows: Array(cloud.running.values),
            planRows: [],
            planDayRows: [],
            planExerciseRows: [],
            planSetRows: []
        )
        await database.mergeCloudRecordsPreservingLocalState(
            strengthSessions: data.strengthSessions,
            runningRecords: data.runningRecords,
            customExercises: data.customExercises
        )
    }

    /// A signed-in device with no seed rows left in it — `prepareForCloudUser`
    /// installs the demo state, and `replaceAll` clears it the way a first
    /// pull would, so the tombstone baseline starts empty.
    static func makeDevice(fileURL: URL? = nil) async -> LocalAppDatabase {
        let database = LocalAppDatabase(fileURL: fileURL ?? tempURL())
        await database.prepareForCloudUser(userId)
        let seeded = await database.fetchProfile()
        await database.replaceAll(
            profile: UserProfile(
                id: userId,
                displayName: "Tester",
                avatarURL: nil,
                membershipLevel: seeded.membershipLevel,
                stats: seeded.stats,
                preferences: seeded.preferences,
                fitnessGoalSummary: nil,
                exercisePRs: []
            ),
            activePlan: TrainingPlan(
                id: UUID().uuidString,
                weekStartDate: WorkoutDateFormatter().string(from: Date()),
                goalSummary: nil,
                coachSummary: "",
                days: []
            ),
            strengthSessions: [],
            runningRecords: [],
            customExercises: [],
            goalSpec: nil
        )
        return database
    }

    static func draft(title: String) -> StrengthSessionDraft {
        StrengthSessionDraft(title: title, workoutDate: Date(), exercises: [exerciseDraft(name: "Bench")])
    }

    static func exerciseDraft(name: String) -> StrengthSessionDraft.ExerciseDraft {
        StrengthSessionDraft.ExerciseDraft(
            name: name,
            exerciseLoadType: .weighted,
            sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 50, weightUnit: .kg, reps: 8, rpe: nil)]
        )
    }

    static func cardioRecord(id: String) -> RunningWorkoutRecord {
        RunningWorkoutRecord(
            id: id,
            userId: userId,
            workoutDate: Date(),
            durationMinutes: 30,
            distanceKm: 5,
            source: .manual,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    static func customExercise(id: String) -> ExerciseDefinition {
        ExerciseDefinition(
            id: id,
            nameEN: "Custom \(id.suffix(4))",
            nameZH: "自定义 \(id.suffix(4))",
            aliases: [],
            muscleGroup: .legs,
            equipment: .other,
            loadType: .weighted,
            popularity: 0,
            isCustom: true
        )
    }

    /// The same rule `LocalAppDatabase` applies: only UUID-shaped ids (after
    /// stripping the `custom-` prefix) were ever pushed, so only they may be
    /// tombstoned.
    static func isUserGenerated(_ id: String) -> Bool {
        let trimmed = id.hasPrefix("custom-") ? String(id.dropFirst("custom-".count)) : id
        return UUID(uuidString: trimmed) != nil
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-record-deletion-\(UUID().uuidString).json")
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fatalError(message()) }
    }
}

enum StubCloudError: Error { case network }

/// One in-memory table set standing in for the five synced record tables.
/// A class so both "devices" write into the same instance, the way they share
/// one Supabase project.
final class StubCloud: @unchecked Sendable {
    var sessions: [String: WorkoutSessionRow] = [:]
    var exercises: [String: ExerciseRow] = [:]
    var sets: [String: ExerciseSetRow] = [:]
    var running: [String: RunningWorkoutRow] = [:]
    var customs: [String: CustomExerciseRow] = [:]

    /// `DELETE … id=in.(…)` — the fix's protocol.
    func delete(table: String, ids: [String]) {
        let doomed = Set(ids)
        switch table {
        case "workout_sessions": sessions = sessions.filter { !doomed.contains($0.key) }
        case "exercises": exercises = exercises.filter { !doomed.contains($0.key) }
        case "exercise_sets": sets = sets.filter { !doomed.contains($0.key) }
        case "running_workouts": running = running.filter { !doomed.contains($0.key) }
        case "custom_exercises": customs = customs.filter { !doomed.contains($0.key) }
        default: fatalError("unexpected delete target \(table)")
        }
    }

    /// `DELETE … id=not.in.(…)` — the protocol Issue #132 is about.
    func keepOnly(
        sessions keepSessions: Set<String>,
        exercises keepExercises: Set<String>,
        sets keepSets: Set<String>,
        running keepRunning: Set<String>,
        customs keepCustoms: Set<String>
    ) {
        sessions = sessions.filter { keepSessions.contains($0.key) }
        exercises = exercises.filter { keepExercises.contains($0.key) }
        sets = sets.filter { keepSets.contains($0.key) }
        running = running.filter { keepRunning.contains($0.key) }
        customs = customs.filter { keepCustoms.contains($0.key) }
    }
}
