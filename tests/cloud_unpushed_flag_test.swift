import Foundation

// Logic test for the persisted "owes a push" flag — the restart-lost-edits
// fix. A mutation made by a signed-in user must survive the process dying
// before its push is confirmed: the flag (plus a mutation counter) is written
// in the same atomic disk write as the mutation, `CloudSyncCoordinator.start()`
// reads it on a cold start to choose push-first over pull-first, and a
// successful push acknowledges the exact snapshot it sent.
//
// Coverage:
//   1. mutation without a cloud owner does not mark the outbox dirty
//      (DEBUG local mode stays fully offline).
//   2. mutation under a prepared cloud user marks it dirty, atomically
//      persisted — a reloaded database (fresh process) still sees it.
//   3. acknowledgePushedState clears the flag only when the acknowledged
//      mutationSeq matches — a mutation landing mid-push keeps it dirty.
//   4. a matching acknowledge clears the flag durably (survives reload).
//   5. mergeFromCloud (a pull) neither clears nor sets the flag, and does
//      not advance the mutation counter.
//   6. prepareForCloudUser for a DIFFERENT user resets the flag with the
//      rest of the state (no cross-account leak).
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
//     tests/cloud_unpushed_flag_test.swift -o /tmp/cuf && /tmp/cuf

@main
struct CloudUnpushedFlagTest {
    static func main() async {
        await testUnownedMutationStaysClean()
        await testOwnedMutationMarksDirtyAndPersists()
        await testStaleAcknowledgeKeepsDirty()
        await testMatchingAcknowledgeClearsDurably()
        await testPullMergeLeavesFlagAlone()
        await testDifferentUserResetsFlag()
        print("cloud_unpushed_flag_test passed")
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-unpushed-flag-test-\(UUID().uuidString).json")
    }

    // 1. No cloud owner (signed out / DEBUG local mode) → never dirty.
    static func testUnownedMutationStaysClean() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        _ = try! await db.createRunningRecord(
            workoutDate: Date(), durationMinutes: 20, distanceKm: 2.5, source: .manual)
        let dirty = await db.hasUnpushedLocalChanges()
        precondition(!dirty, "a mutation without a cloud owner must not mark the outbox dirty")
    }

    // 2. Owned mutation → dirty, and the flag rides the same disk write as
    //    the mutation: a fresh database on the same file (i.e. the next
    //    process) still sees both.
    static func testOwnedMutationMarksDirtyAndPersists() async {
        let url = tempURL()
        let db = LocalAppDatabase(fileURL: url)
        await db.prepareForCloudUser("user-a")

        let before = await db.snapshot().mutationSeq
        let record = try! await db.createRunningRecord(
            workoutDate: Date(), durationMinutes: 20, distanceKm: 2.5, source: .manual)
        let after = await db.snapshot().mutationSeq

        let dirty = await db.hasUnpushedLocalChanges()
        precondition(dirty, "an owned mutation must mark the outbox dirty")
        precondition(after > before, "each owned mutation must advance the mutation counter")

        let reloaded = LocalAppDatabase(fileURL: url)
        let reloadedDirty = await reloaded.hasUnpushedLocalChanges()
        let reloadedRecords = await reloaded.snapshot().runningRecords
        precondition(reloadedDirty,
            "the dirty flag must survive a cold start alongside the mutation it marks")
        precondition(reloadedRecords.contains { $0.id == record.id },
            "the mutation itself must be on disk with the flag")
    }

    // 3. A mutation landing after the pushed snapshot keeps the flag set.
    static func testStaleAcknowledgeKeepsDirty() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        await db.prepareForCloudUser("user-a")
        _ = try! await db.createRunningRecord(
            workoutDate: Date(), durationMinutes: 20, distanceKm: 2.5, source: .manual)

        let pushedSeq = await db.snapshot().mutationSeq
        // A second mutation lands while the push is in flight.
        _ = try! await db.createRunningRecord(
            workoutDate: Date(), durationMinutes: 30, distanceKm: 4.0, source: .manual)

        await db.acknowledgePushedState(mutationSeq: pushedSeq)
        let dirty = await db.hasUnpushedLocalChanges()
        precondition(dirty,
            "acknowledging a stale snapshot must not mark the newer mutation as pushed")
    }

    // 4. Matching acknowledge clears the flag, durably.
    static func testMatchingAcknowledgeClearsDurably() async {
        let url = tempURL()
        let db = LocalAppDatabase(fileURL: url)
        await db.prepareForCloudUser("user-a")
        _ = try! await db.createRunningRecord(
            workoutDate: Date(), durationMinutes: 20, distanceKm: 2.5, source: .manual)

        let pushedSeq = await db.snapshot().mutationSeq
        await db.acknowledgePushedState(mutationSeq: pushedSeq)

        let dirty = await db.hasUnpushedLocalChanges()
        precondition(!dirty, "a matching acknowledge must clear the flag")

        let reloaded = LocalAppDatabase(fileURL: url)
        let reloadedDirty = await reloaded.hasUnpushedLocalChanges()
        precondition(!reloadedDirty,
            "the cleared flag must be persisted — a cold start right after a successful push must not re-push")
    }

    // 5. A pull (mergeFromCloud) is the sync writing in, not the user
    //    mutating: it must not touch the flag or the counter in either
    //    direction. (The revision-guard path pulls mid-push; clearing the
    //    flag there would mark unpushed edits as pushed.)
    static func testPullMergeLeavesFlagAlone() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        await db.prepareForCloudUser("user-a")
        _ = try! await db.createRunningRecord(
            workoutDate: Date(), durationMinutes: 20, distanceKm: 2.5, source: .manual)
        let dirtyBefore = await db.hasUnpushedLocalChanges()
        let seqBefore = await db.snapshot().mutationSeq
        precondition(dirtyBefore, "setup: outbox should be dirty")

        let profile = await db.fetchProfile()
        let plan = await db.activePlan()!
        await db.mergeFromCloud(profile: profile, activePlan: plan,
            strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        let dirtyAfter = await db.hasUnpushedLocalChanges()
        let seqAfter = await db.snapshot().mutationSeq
        precondition(dirtyAfter, "mergeFromCloud must not clear the dirty flag")
        precondition(seqAfter == seqBefore, "mergeFromCloud must not advance the mutation counter")
    }

    // 6. Switching accounts resets the flag with the rest of the cache.
    static func testDifferentUserResetsFlag() async {
        let url = tempURL()
        let db = LocalAppDatabase(fileURL: url)
        await db.prepareForCloudUser("user-a")
        _ = try! await db.createRunningRecord(
            workoutDate: Date(), durationMinutes: 20, distanceKm: 2.5, source: .manual)
        let dirtyAsA = await db.hasUnpushedLocalChanges()
        precondition(dirtyAsA, "setup: outbox should be dirty for user-a")

        await db.prepareForCloudUser("user-b")
        let dirtyAsB = await db.hasUnpushedLocalChanges()
        precondition(!dirtyAsB,
            "user-a's unpushed flag must not leak into user-b's session (the cache was discarded)")
    }
}
