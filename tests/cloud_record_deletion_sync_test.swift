import Foundation

// Logic test for the Issue #132 fix and its Issue #148 completion: a push must
// delete only the records the user actually deleted, never the records it
// merely has not heard of — and a *pull* must carry another device's deletions
// in, rather than leaving the local copy to be re-upserted.
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
//      still in it, the deletion wins anyway (delete-wins, matching the
//      database's ON DELETE CASCADE) and the row is stripped back out — a push
//      still never upserts and deletes the same id.
//   8. running_workouts / custom_exercises tombstones, including the
//      `custom-<uuid>` → bare-uuid translation the cloud PK needs, and the
//      seed-id guard that keeps never-pushed rows out of the DELETE.
//   9. a push carrying no prune at all still delivers the deletion, and a
//      failed DELETE leaves the intent pending instead of acknowledging it
//      away (Codex P2 on #141: a skipped prune used to undo the user's
//      deletion silently, because absence was the only delete channel).
//  10. a tombstone confirmation that cannot be written to disk fails the push
//      instead of being swallowed, so a restart never holds a deletion intent
//      nothing will re-send or retire.
//  11. (Issue #148) B's deletion reaches A through the server-side
//      `record_deletions` log, and A's next push does not put the row back —
//      paired with the same fixture under a pull that carries no deletion log,
//      where it is resurrected.
//  12. the database's ON DELETE CASCADE and the local merge give the same
//      answer for "A deleted the session while B added a set under it": the
//      cascade destroys B's row and tombstones it, and B's merge drops it
//      instead of re-upserting an orphan.
//  13. a device returning inside the retention window gets the deletions it
//      missed; one returning after the sweep has purged them does not, and the
//      documented degradation is that the record reappears (never that
//      anything is destroyed) and converges on the next deletion.
//  14. the deletion cursor is incremental, only ever moves forward, and the
//      deliberate re-read overlap is idempotent.
//  15. a nested deletion survives the local state file being replaced
//      wholesale — the intent is no longer stored only there.
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
        try await testDeleteBeatsAConcurrentEditOfTheSameSession()
        try await testSkippedPruneCannotSilentlyUndoADeletion()
        try await testFailedDeleteKeepsTheIntentPending()
        try await testUnwritableConfirmationFailsThePush()
        testRunningAndCustomExerciseTombstones()
        try await testRemoteDeletionReachesTheOtherDevice()
        try await testWithoutTheServerLogTheDeletionIsUndone()
        try await testCascadeAndLocalMergeAgree()
        try await testLongOfflineDeviceWithinAndBeyondRetention()
        try await testDeletionCursorIsIncrementalAndIdempotent()
        try await testNestedDeletionSurvivesALocalStateFileReplacement()
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

    // MARK: - 7: delete beats a concurrent edit of the same session

    /// A deletes an exercise out of a session; B edits the same session
    /// afterwards, so B's copy is the newer one. When A pulls, last-write-wins
    /// hands the session back whole — deleted exercise included.
    ///
    /// Before Issue #148 this was resolved by dropping A's tombstone: the row
    /// came back, update-wins. That was the local half of gap 3 — the database
    /// resolves the same shape of conflict with `ON DELETE CASCADE`, i.e.
    /// delete-wins, so the two sides answered the same question differently
    /// depending on which one you asked. It is delete-wins on both sides now:
    /// the tombstone stands and the resurrected exercise is stripped back out
    /// of the merged state, which keeps the invariant this test was originally
    /// written for — a push never upserts and deletes the same id — by the
    /// other route.
    static func testDeleteBeatsAConcurrentEditOfTheSameSession() async throws {
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

        // The fixture really does put the contested exercise back in the merge
        // input — without this the test would pass for the wrong reason. Model
        // the pre-#148 local rule (drop the tombstone, keep the row) directly
        // against the same state to show the two rules disagree here, which is
        // the whole point of gap 3.
        let cloudSession = CloudMapper.assembleSnapshot(
            userId: userId, profileRow: nil, preferencesRow: nil, goalSpecRow: nil,
            customRows: [], sessionRows: Array(cloud.sessions.values),
            exerciseRows: Array(cloud.exercises.values), setRows: Array(cloud.sets.values),
            runningRows: [], planRows: [], planDayRows: [], planExerciseRows: [], planSetRows: []
        ).strengthSessions.first { $0.id == session.id }
        expect(cloudSession?.exercises.contains { $0.id == contested.id } == true,
               "fixture: the cloud copy that wins LWW should still contain the contested exercise")
        let underOldRule = (await deviceA.snapshot()).pendingRecordDeletions
            .clearingIdsPresent(in: RecordIdentitySet(
                strengthSessions: [cloudSession!], runningRecords: [], customExercises: []
            ))
        expect(underOldRule.exercises.isEmpty,
               "fixture no longer reproduces the update-wins/delete-wins disagreement")

        await pull(deviceA, from: cloud)
        let merged = await deviceA.snapshot()
        let mergedSession = merged.strengthSessions.first { $0.id == session.id }
        expect(mergedSession != nil, "the surviving session was dropped along with the exercise")
        expect(mergedSession?.exercises.contains { $0.id == contested.id } == false,
               "delete must beat the concurrent edit: the exercise came back")
        expect(mergedSession?.exercises.contains { $0.id == session.exercises[0].id } == true,
               "B's edit to the rest of the session must survive")
        expect(merged.pendingRecordDeletions.exercises == [contested.id],
               "the deletion intent must survive the merge: \(merged.pendingRecordDeletions.exercises)")

        try await push(deviceA, to: cloud, using: .tombstones)
        expect(cloud.exercises[contested.id] == nil,
               "the deletion never reached the cloud")
        expect(cloud.exercises[session.exercises[0].id] != nil,
               "the sibling exercise was destroyed")
        // The invariant the old rule protected, preserved the other way round:
        // the id is not in the pushed state at all, so it cannot be both
        // upserted and deleted.
        let pushed = await deviceA.snapshot()
        expect(!RecordIdentitySet(snapshot: pushed).exercises.contains(contested.id),
               "a tombstoned id must not be in the set the push upserts")
    }

    // MARK: - 11: the headline for #148 — B's deletion reaches A

    /// B deletes a record and pushes. A, which still has it cached, pulls: the
    /// server deletion log has to carry the intent across, and A's next push
    /// must not put the row back.
    ///
    /// This is the gap PR #146 left open. The tombstone it introduced is
    /// *local* — it tells the cloud what this device deleted, not what the
    /// other one did — so A's merge kept its copy and re-upserted it, and the
    /// deletion was silently undone.
    static func testRemoteDeletionReachesTheOtherDevice() async throws {
        let world = try await remoteDeletionWorld(deletions: .serverLog)

        let onA = await world.deviceA.snapshot()
        expect(!onA.strengthSessions.contains { $0.id == world.doomedSession },
               "A's pull did not apply B's session deletion")
        expect(!onA.runningRecords.contains { $0.id == world.doomedRun },
               "A's pull did not apply B's cardio deletion")
        expect(!onA.customExercises.contains { $0.id == world.doomedCustom },
               "A's pull did not apply B's custom-exercise deletion")
        expect(onA.strengthSessions.contains { $0.id == world.keptSession },
               "A's pull deleted a record nothing was tombstoned for")

        // And the cloud stays deleted after A pushes: the rows are gone from
        // A's snapshot, so there is nothing left to re-upsert.
        try await push(world.deviceA, to: world.cloud, using: .tombstones)
        expect(world.cloud.sessions[world.doomedSession] == nil,
               "A's push resurrected the session B deleted")
        expect(world.cloud.running[world.doomedRun] == nil,
               "A's push resurrected the cardio record B deleted")
        expect(world.cloud.customs[CloudMapper.strippedCustomId(world.doomedCustom)] == nil,
               "A's push resurrected the custom exercise B deleted")
        expect(world.cloud.sessions[world.keptSession] != nil, "A's push lost an untouched session")
    }

    /// The same fixture with the pre-#148 pull — no deletion log — so the test
    /// cannot pass just because the scenario stopped reproducing the bug.
    static func testWithoutTheServerLogTheDeletionIsUndone() async throws {
        let world = try await remoteDeletionWorld(deletions: .none)

        let onA = await world.deviceA.snapshot()
        expect(onA.strengthSessions.contains { $0.id == world.doomedSession },
               "fixture no longer reproduces the resurrection")
        try await push(world.deviceA, to: world.cloud, using: .tombstones)
        expect(world.cloud.sessions[world.doomedSession] != nil,
               "fixture no longer reproduces the resurrection: A's push should have put the row back")
    }

    struct RemoteDeletionWorld {
        let cloud: StubCloud
        let deviceA: LocalAppDatabase
        let deviceB: LocalAppDatabase
        let doomedSession: String
        let doomedExercise: String
        let doomedRun: String
        let doomedCustom: String
        let keptSession: String
    }

    static func remoteDeletionWorld(
        deletions: DeletionPullProtocol
    ) async throws -> RemoteDeletionWorld {
        let cloud = StubCloud()
        let deviceA = await makeDevice()
        let deviceB = await makeDevice()

        let doomed = try await deviceA.createStrengthSession(draft(title: "doomed"))
        let kept = try await deviceA.createStrengthSession(draft(title: "kept"))
        let run = try await deviceA.createRunningRecord(
            workoutDate: Date(), durationMinutes: 30, distanceKm: 5, source: .manual
        )
        let custom = try await deviceA.addCustomExercise(
            name: "Zercher Squat", muscleGroup: .legs, loadType: .weighted
        )
        try await push(deviceA, to: cloud, using: .tombstones)
        // Both devices now hold everything.
        await pull(deviceB, from: cloud, deletions: deletions)
        await pull(deviceA, from: cloud, deletions: deletions)

        // B deletes and pushes. `LocalAppDatabase` has no delete path for cardio
        // records or custom exercises, so those two go through the same seam the
        // production push uses (`deleteTargets`) with a hand-built log — the
        // level at which that plumbing exists, as in case 8.
        try await deviceB.deleteExercise(sessionId: doomed.id, exerciseId: doomed.exercises[0].id)
        try await push(deviceB, to: cloud, using: .tombstones)
        cloud.delete(table: "running_workouts", ids: [run.id])
        cloud.delete(table: "custom_exercises", ids: [CloudMapper.strippedCustomId(custom.id)])

        await pull(deviceA, from: cloud, deletions: deletions)

        return RemoteDeletionWorld(
            cloud: cloud,
            deviceA: deviceA,
            deviceB: deviceB,
            doomedSession: doomed.id,
            doomedExercise: doomed.exercises[0].id,
            doomedRun: run.id,
            doomedCustom: custom.id,
            keptSession: kept.id
        )
    }

    // MARK: - 12: the cascade and the local merge must agree

    /// A deletes a whole session while B, which never saw the delete, adds a
    /// set to one of its exercises. The database resolves this by cascading:
    /// A's DELETE on `workout_sessions` destroys the exercises and every set
    /// under them, B's new row included, and the trigger tombstones each one.
    ///
    /// The client has to reach the same answer. Before this change it did not:
    /// B's merge kept its own row (nothing told it otherwise) and re-upserted
    /// an orphan. The rule is now the same on both sides — delete-wins, per
    /// row — and B learns about *its own* row because the tombstone is written
    /// by the cascade, not by the deleting device's guess at what was under
    /// there.
    static func testCascadeAndLocalMergeAgree() async throws {
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

        // B adds a set A will never hear about, and pushes it.
        let setByB = try await deviceB.addSet(
            sessionId: session.id,
            exerciseId: session.exercises[0].id,
            weight: 70, weightUnit: .kg, reps: 8
        )
        try await push(deviceB, to: cloud, using: .tombstones)

        // A deletes the whole session without ever pulling B's set.
        for exercise in session.exercises {
            try? await deviceA.deleteExercise(sessionId: session.id, exerciseId: exercise.id)
        }
        let pendingOnA = await deviceA.snapshot().pendingRecordDeletions
        expect(!pendingOnA.exerciseSets.contains(setByB.id),
               "fixture: A must not know about B's set — that is what makes the cascade load-bearing")
        try await push(deviceA, to: cloud, using: .tombstones)

        expect(cloud.sets[setByB.id] == nil, "the cascade should have destroyed B's set")

        await pull(deviceB, from: cloud)
        let onB = await deviceB.snapshot()
        expect(!onB.strengthSessions.contains { $0.id == session.id },
               "B kept a session the cascade destroyed")
        // Same answer on both sides: the row is gone in the cloud and gone on
        // B, so B's next push cannot recreate it (and would violate the foreign
        // key if it tried).
        expect(!RecordIdentitySet(snapshot: onB).exerciseSets.contains(setByB.id),
               "B would re-upsert a set whose parent rows no longer exist")

        try await push(deviceB, to: cloud, using: .tombstones)
        expect(cloud.sets[setByB.id] == nil, "B's push resurrected the cascaded set")
        expect(cloud.sessions[session.id] == nil, "B's push resurrected the deleted session")
    }

    // MARK: - 13: retention window and the long-offline device

    /// A device that comes back inside the retention window gets the deletions
    /// it missed; one that comes back after the tombstones have been purged
    /// does not, and the documented degradation is that the record reappears —
    /// never that anything is destroyed.
    static func testLongOfflineDeviceWithinAndBeyondRetention() async throws {
        // Inside the window: the tombstone is still there, so a device whose
        // cursor is far behind (or nil — it has never read the log) gets it.
        let cloud = StubCloud()
        let deviceA = await makeDevice()
        let deviceB = await makeDevice()
        let doomed = try await deviceA.createStrengthSession(draft(title: "doomed"))
        try await push(deviceA, to: cloud, using: .tombstones)
        await pull(deviceB, from: cloud)

        try await deviceA.deleteExercise(sessionId: doomed.id, exerciseId: doomed.exercises[0].id)
        try await push(deviceA, to: cloud, using: .tombstones)

        let (cursorBefore, _) = await deviceB.recordDeletionSyncState()
        expect(cursorBefore == nil, "fixture: B has never seen a tombstone, so its cursor is nil")
        await pull(deviceB, from: cloud)
        expect(!(await deviceB.snapshot()).strengthSessions.contains { $0.id == doomed.id },
               "a device returning inside the retention window must still get the deletion")
        let (cursorAfter, pulledAt) = await deviceB.recordDeletionSyncState()
        expect(cursorAfter != nil, "a completed deletion read must advance the cursor")
        expect(pulledAt != nil, "a completed deletion read must record when it happened")

        // Beyond the window: same fixture, but the retention sweep has already
        // taken the tombstone. Nothing tells the returning device, so its copy
        // survives — and that is the whole degradation: it comes back, it is
        // not destroyed, and deleting it again converges.
        let staleCloud = StubCloud()
        let deviceC = await makeDevice()
        let deviceD = await makeDevice()
        let expired = try await deviceC.createStrengthSession(draft(title: "expired"))
        try await push(deviceC, to: staleCloud, using: .tombstones)
        await pull(deviceD, from: staleCloud)
        try await deviceC.deleteExercise(sessionId: expired.id, exerciseId: expired.exercises[0].id)
        try await push(deviceC, to: staleCloud, using: .tombstones)
        staleCloud.purgeAllTombstones()

        await pull(deviceD, from: staleCloud)
        expect((await deviceD.snapshot()).strengthSessions.contains { $0.id == expired.id },
               "fixture: with the tombstone purged there is nothing left to tell D")
        try await push(deviceD, to: staleCloud, using: .tombstones)
        expect(staleCloud.sessions[expired.id] != nil,
               "fixture: the documented degradation is that the row comes back, not that it vanishes")
        // …and it converges the moment either device deletes it again, this
        // time with a live tombstone.
        try await deviceD.deleteExercise(sessionId: expired.id, exerciseId: expired.exercises[0].id)
        try await push(deviceD, to: staleCloud, using: .tombstones)
        await pull(deviceC, from: staleCloud)
        expect(!(await deviceC.snapshot()).strengthSessions.contains { $0.id == expired.id },
               "the second deletion must propagate normally")
    }

    // MARK: - 14: the cursor is incremental, and re-reads are harmless

    /// The pull reads `record_deletions` from its cursor forward, the cursor
    /// only ever moves forward, and the deliberate overlap means a tombstone
    /// can be applied twice with no effect.
    static func testDeletionCursorIsIncrementalAndIdempotent() async throws {
        let cloud = StubCloud()
        let deviceA = await makeDevice()
        let deviceB = await makeDevice()

        let first = try await deviceA.createStrengthSession(draft(title: "first"))
        let second = try await deviceA.createStrengthSession(draft(title: "second"))
        try await push(deviceA, to: cloud, using: .tombstones)
        await pull(deviceB, from: cloud)

        try await deviceA.deleteExercise(sessionId: first.id, exerciseId: first.exercises[0].id)
        try await push(deviceA, to: cloud, using: .tombstones)
        await pull(deviceB, from: cloud)
        let (afterFirst, _) = await deviceB.recordDeletionSyncState()
        expect(afterFirst != nil, "the first deletion read must set a cursor")

        // A second pull with nothing new must not rewind the cursor…
        await pull(deviceB, from: cloud)
        let (afterIdle, _) = await deviceB.recordDeletionSyncState()
        expect(afterIdle == afterFirst, "an idle pull moved the cursor: \(String(describing: afterIdle))")
        // …and re-applying the same tombstone (the overlap window guarantees it
        // is re-read) changes nothing.
        expect(!(await deviceB.snapshot()).strengthSessions.contains { $0.id == first.id },
               "a re-read tombstone must stay applied")
        expect((await deviceB.snapshot()).strengthSessions.contains { $0.id == second.id },
               "a re-read tombstone must not spread to other rows")

        try await deviceA.deleteExercise(sessionId: second.id, exerciseId: second.exercises[0].id)
        try await push(deviceA, to: cloud, using: .tombstones)
        await pull(deviceB, from: cloud)
        let (afterSecond, _) = await deviceB.recordDeletionSyncState()
        expect(afterSecond! > afterFirst!, "a newer tombstone must advance the cursor")
        expect((await deviceB.snapshot()).strengthSessions.isEmpty,
               "the second deletion did not reach B")
    }

    // MARK: - 15: nested deletions no longer depend on the local state file

    /// Gap 2's structural half. A deletion intent that lives only in the local
    /// state file is lost when that file is replaced — which is exactly what an
    /// upgrade from the pre-tombstone format does, and why a *nested* deletion
    /// (an exercise removed from a session that survives) went missing.
    ///
    /// What this pins is that the intent no longer lives only there: once the
    /// DELETE lands, the server holds the tombstone, so a device whose state
    /// file is wiped and re-seeded — a reinstall, a corrupt file, a format
    /// change — still learns the row is gone instead of re-upserting it. The
    /// legacy pre-upgrade intent itself is unrecoverable and is documented as
    /// such in `LocalAppState.init(from:)`; nothing anywhere records it.
    static func testNestedDeletionSurvivesALocalStateFileReplacement() async throws {
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
        try await deviceA.deleteExercise(sessionId: session.id, exerciseId: removed.id)
        try await push(deviceA, to: cloud, using: .tombstones)
        expect(cloud.exercises[removed.id] == nil, "fixture: the nested deletion should have landed")

        // A fresh state file — no `pendingRecordDeletions`, nothing at all —
        // standing in for the upgrade/reinstall that used to lose this.
        let reinstalled = await makeDevice()
        let (cursor, _) = await reinstalled.recordDeletionSyncState()
        expect(cursor == nil, "fixture: a fresh cache must start with no deletion cursor")
        await pull(reinstalled, from: cloud)

        let restored = await reinstalled.snapshot()
        let restoredSession = restored.strengthSessions.first { $0.id == session.id }
        expect(restoredSession != nil, "the surviving session should have been pulled")
        expect(restoredSession?.exercises.contains { $0.id == removed.id } == false,
               "the nested deletion did not survive the state-file replacement")
        expect(restoredSession?.exercises.contains { $0.id == session.exercises[0].id } == true,
               "the surviving exercise was lost")

        try await push(reinstalled, to: cloud, using: .tombstones)
        expect(cloud.exercises[removed.id] == nil, "the reinstalled device re-upserted the deleted exercise")
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

    // MARK: - 10: a tombstone confirmation that cannot be written must fail

    /// The cloud DELETE succeeded, so those rows are gone — but the write that
    /// retires their tombstones failed. Swallowing that and letting the push
    /// acknowledge clean would leave a restart holding a deletion intent
    /// nothing is going to re-send or clear. Throwing keeps the push dirty,
    /// and re-sending a delete-by-id on the retry costs nothing.
    static func testUnwritableConfirmationFailsThePush() async throws {
        guard getuid() != 0 else {
            print("  (skipped testUnwritableConfirmationFailsThePush: running as root)")
            return
        }
        let cloud = StubCloud()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let deviceA = await makeDevice(fileURL: directory.appendingPathComponent("state.json"))

        let doomed = try await deviceA.createStrengthSession(draft(title: "to delete"))
        try await push(deviceA, to: cloud, using: .tombstones)
        try await deviceA.deleteExercise(sessionId: doomed.id, exerciseId: doomed.exercises[0].id)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        var threw = false
        do {
            try await push(deviceA, to: cloud, using: .tombstones)
        } catch {
            threw = true
        }
        expect(threw, "an unwritable confirmation must fail the push, not be swallowed")
        // Targets run children-first, so `exercise_sets` is the one that got
        // as far as a DELETE before its confirmation failed; the tables after
        // it were never attempted.
        expect(cloud.sets[doomed.exercises[0].sets[0].id] == nil, "fixture: the first DELETE should have landed")
        expect(cloud.sessions[doomed.id] != nil, "fixture: later tables should not have been attempted")

        let stillPending = await deviceA.snapshot().pendingRecordDeletions
        expect(stillPending.sessions == [doomed.id],
               "the session tombstone must survive the failed push: \(stillPending)")
        expect(stillPending.exerciseSets == [doomed.exercises[0].sets[0].id],
               "the in-memory tombstone must roll back with the failed write: \(stillPending)")

        // With the directory writable again the retry re-sends a delete-by-id
        // (a no-op against the already-deleted row) and retires the tombstone.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await push(deviceA, to: cloud, using: .tombstones)
        let cleared = await deviceA.snapshot().pendingRecordDeletions
        expect(cleared.isEmpty, "the retry did not retire the tombstone: \(cleared)")
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
                try await database.clearPushedRecordDeletions(target.confirmation)
            }
        }

        await database.acknowledgePushedState(mutationSeq: snapshot.mutationSeq)
    }

    /// Mirrors the record half of `CloudSyncCoordinator.pull`, including the
    /// order it reads in: rows first, then the deletion log. Reading them the
    /// other way round loses any deletion that commits between the two reads —
    /// see the comment on `CloudSyncCoordinator.pull`.
    ///
    /// - Parameter deletionProtocol: `.serverLog` is the fix; `.none` is what
    ///   shipped before Issue #148 — a pull that carries no deletions at all —
    ///   kept for the same reason `.absencePrune` is kept above: every "the
    ///   deletion propagated" assertion is paired with one showing the same
    ///   fixture leaves it undone without this.
    static func pull(
        _ database: LocalAppDatabase,
        from cloud: StubCloud,
        deletions deletionProtocol: DeletionPullProtocol = .serverLog
    ) async {
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
        var remote = RemoteRecordDeletions()
        if case .serverLog = deletionProtocol {
            let (cursor, _) = await database.recordDeletionSyncState()
            remote = cloud.deletionLog(since: cursor)
        }
        await database.mergeCloudRecordsPreservingLocalState(
            strengthSessions: data.strengthSessions,
            runningRecords: data.runningRecords,
            customExercises: data.customExercises,
            remoteDeletions: remote
        )
    }

    enum DeletionPullProtocol {
        /// The fix: read `record_deletions` from this cache's cursor forward
        /// and apply it.
        case serverLog
        /// What shipped before Issue #148: a pull that only ever adds rows, so
        /// another device's deletion never arrives.
        case none
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

/// One row of the server-side `record_deletions` table.
struct StubTombstone {
    let table: String
    /// Cloud id space — the bare uuid, as the real column holds it.
    let id: String
    let deletedAt: Date
}

/// One in-memory table set standing in for the five synced record tables.
/// A class so both "devices" write into the same instance, the way they share
/// one Supabase project.
///
/// Two server-side behaviours are modelled here because the protocol depends on
/// them and neither is client code:
///
///   * `ON DELETE CASCADE` from the schema — deleting a session destroys its
///     exercises and their sets, *including rows the deleting device never
///     heard of*;
///   * the `AFTER DELETE` trigger from migration 20260731090000 — every row the
///     delete actually destroys, cascaded ones included, leaves a tombstone.
///
/// Getting the cascade wrong here would make the tests agree with a database
/// that does not exist, which is precisely the class of bug Issue #148's gap 3
/// is about.
final class StubCloud: @unchecked Sendable {
    var sessions: [String: WorkoutSessionRow] = [:]
    var exercises: [String: ExerciseRow] = [:]
    var sets: [String: ExerciseSetRow] = [:]
    var running: [String: RunningWorkoutRow] = [:]
    var customs: [String: CustomExerciseRow] = [:]
    /// `record_deletions`. Append-only from the client's point of view: RLS
    /// grants SELECT and nothing else.
    private(set) var tombstones: [StubTombstone] = []

    /// A monotonic stand-in for `now()`, so cursor arithmetic in the tests is
    /// deterministic instead of racing the wall clock.
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func tick() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    /// `DELETE … id=in.(…)` — the fix's protocol — plus the cascade and the
    /// trigger that ride along with it server-side.
    func delete(table: String, ids: [String]) {
        let doomed = Set(ids)
        switch table {
        case "workout_sessions":
            let goingExercises = exercises.values.filter { doomed.contains($0.session_id) }.map(\.id)
            remove(table: "workout_sessions", ids: doomed.filter { sessions[$0] != nil })
            delete(table: "exercises", ids: goingExercises)
        case "exercises":
            let goingSets = sets.values.filter { doomed.contains($0.exercise_id) }.map(\.id)
            remove(table: "exercises", ids: doomed.filter { exercises[$0] != nil })
            delete(table: "exercise_sets", ids: goingSets)
        case "exercise_sets":
            remove(table: "exercise_sets", ids: doomed.filter { sets[$0] != nil })
        case "running_workouts":
            remove(table: "running_workouts", ids: doomed.filter { running[$0] != nil })
        case "custom_exercises":
            remove(table: "custom_exercises", ids: doomed.filter { customs[$0] != nil })
        default: fatalError("unexpected delete target \(table)")
        }
    }

    /// Drops the rows and records their tombstones in one step — the trigger
    /// fires inside the deleting statement's transaction, so a row can never be
    /// gone without a tombstone naming it.
    private func remove(table: String, ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        let doomed = Set(ids)
        switch table {
        case "workout_sessions": sessions = sessions.filter { !doomed.contains($0.key) }
        case "exercises": exercises = exercises.filter { !doomed.contains($0.key) }
        case "exercise_sets": sets = sets.filter { !doomed.contains($0.key) }
        case "running_workouts": running = running.filter { !doomed.contains($0.key) }
        case "custom_exercises": customs = customs.filter { !doomed.contains($0.key) }
        default: fatalError("unexpected delete target \(table)")
        }
        let stamp = tick()
        for id in doomed.sorted() where !tombstones.contains(where: { $0.table == table && $0.id == id }) {
            tombstones.append(StubTombstone(table: table, id: id, deletedAt: stamp))
        }
    }

    /// The read side of `record_deletions`, mirroring
    /// `CloudSnapshotLoader.loadRecordDeletions`: everything at or after
    /// `cursor - overlap`, translated into local id space.
    func deletionLog(since cursor: Date?) -> RemoteRecordDeletions {
        let floor = cursor.map { $0.addingTimeInterval(-RemoteRecordDeletions.cursorOverlap) }
        var log = RecordDeletionLog()
        var newest: Date?
        for row in tombstones where floor == nil || row.deletedAt >= floor! {
            log.insertCloudId(row.id, table: row.table, customExerciseLocalId: CloudMapper.localCustomId)
            if row.deletedAt > (newest ?? .distantPast) { newest = row.deletedAt }
        }
        return RemoteRecordDeletions(log: log, newestDeletedAt: newest)
    }

    /// `purge_record_deletions()` — the retention sweep. Ages every tombstone
    /// out, which is how the "device offline longer than the window" case is
    /// reproduced without waiting 180 days.
    func purgeAllTombstones() {
        tombstones.removeAll()
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
