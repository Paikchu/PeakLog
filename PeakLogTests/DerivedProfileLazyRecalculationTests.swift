import XCTest
@testable import PeakLog

/// Issue #17: `recalculateDerivedProfile()` used to run (an O(N) walk over
/// every session/set) on every single mutation. It's now deferred behind a
/// dirty flag and only recomputed on the next read (`fetchProfile()` /
/// `snapshot()`). These tests pin the *externally observable* contract: no
/// matter how many mutations land before a read, the next read always
/// reflects all of them.
@MainActor
final class DerivedProfileLazyRecalculationTests: XCTestCase {
    private var databaseFileURL: URL!
    private var database: LocalAppDatabase!

    override func setUp() {
        super.setUp()
        databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived-profile-lazy-tests-\(UUID().uuidString).json")
        database = LocalAppDatabase(fileURL: databaseFileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: databaseFileURL)
        super.tearDown()
    }

    // A single mutation still shows up correctly on the next read.
    func testFetchProfileReflectsVolumeAfterSingleMutation() async throws {
        let before = await database.fetchProfile()

        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Lazy Recalc Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Lazy Deadlift",
                    sets: [
                        StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 100, weightUnit: .kg, reps: 5, rpe: nil)
                    ]
                )
            ]
        ))

        let after = await database.fetchProfile()
        XCTAssertEqual(after.stats.totalVolumeKg, before.stats.totalVolumeKg + 500, accuracy: 0.001)
        XCTAssertEqual(after.stats.workoutsCount, before.stats.workoutsCount + 1)
    }

    // Several mutations land before any read of the profile happens; the
    // deferred recompute must still fold in every one of them, not just the
    // most recent, when the profile is finally read.
    func testFetchProfileFoldsInMultiplePendingMutationsBeforeAnyRead() async throws {
        let before = await database.fetchProfile()

        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Batch Session A",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Batch Squat",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 80, weightUnit: .kg, reps: 5, rpe: nil)]
                )
            ]
        ))
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Batch Session B",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Batch Bench",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 60, weightUnit: .kg, reps: 5, rpe: nil)]
                )
            ]
        ))
        let record = try await database.createRunningRecord(
            workoutDate: Date(),
            durationMinutes: 20,
            distanceKm: 4,
            source: .manual
        )

        // No fetchProfile() call between the three mutations above — the
        // dirty flag should still coalesce all of them into one recompute.
        let after = await database.fetchProfile()
        XCTAssertEqual(after.stats.totalVolumeKg, before.stats.totalVolumeKg + 400 + 300, accuracy: 0.001)
        XCTAssertEqual(after.stats.workoutsCount, before.stats.workoutsCount + 3)
        _ = record
    }

    // snapshot() (used by cloud sync) must see the same freshly-recomputed
    // data as fetchProfile(), not a stale pre-mutation copy.
    func testSnapshotReflectsPendingMutation() async throws {
        let beforeSnapshot = await database.snapshot()

        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Snapshot Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Snapshot Row",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 40, weightUnit: .kg, reps: 10, rpe: nil)]
                )
            ]
        ))

        let afterSnapshot = await database.snapshot()
        XCTAssertEqual(
            afterSnapshot.profile.stats.totalVolumeKg,
            beforeSnapshot.profile.stats.totalVolumeKg + 400,
            accuracy: 0.001
        )
    }

    // A brand-new PR must appear in `exercisePRs` on the next read even when
    // several other mutations were pending first.
    func testNewPRIsVisibleAfterDeferredRecalculation() async throws {
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Warm-up Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "PR Overhead Press",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 30, weightUnit: .kg, reps: 8, rpe: nil)]
                )
            ]
        ))
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "PR Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "PR Overhead Press",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 45, weightUnit: .kg, reps: 3, rpe: nil)]
                )
            ]
        ))

        let profile = await database.fetchProfile()
        let pr = try XCTUnwrap(profile.exercisePRs.first { $0.displayName == "PR Overhead Press" })
        XCTAssertEqual(pr.maxWeight, 45, accuracy: 0.001)
    }
}
