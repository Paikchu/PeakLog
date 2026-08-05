import XCTest
@testable import PeakLog

final class TrainingSessionSummaryTests: XCTestCase {
    // MARK: - Fixtures

    private func set(
        _ id: String,
        index: Int,
        weight: Double?,
        unit: WeightUnit = .kg,
        reps: Int
    ) -> PlanLiveWorkoutSet {
        PlanLiveWorkoutSet(
            id: id,
            setIndex: index,
            targetWeight: weight,
            targetWeightUnit: unit,
            targetReps: reps,
            isAlreadyCompleted: false
        )
    }

    private func session(
        exercises: [PlanLiveWorkoutExercise],
        completed: Set<String>,
        skipped: Set<String> = [],
        startedAt: Date? = nil
    ) -> PlanLiveWorkoutSession {
        PlanLiveWorkoutSession(
            id: "session-1",
            title: "Push Day",
            focus: "Chest",
            exercises: exercises,
            currentExerciseIndex: 0,
            currentSetIndex: 0,
            completedSetIds: completed,
            manualFocusExerciseId: nil,
            skippedExerciseIds: skipped,
            startedAt: startedAt
        )
    }

    private func exercise(
        id: String = "e1",
        name: String = "Bench Press",
        sets: [PlanLiveWorkoutSet]
    ) -> PlanLiveWorkoutExercise {
        PlanLiveWorkoutExercise(id: id, name: name, loadType: .weighted, sets: sets)
    }

    // MARK: - Volume

    func testVolumeCountsOnlyCompletedSets() {
        let live = session(
            exercises: [exercise(sets: [
                set("s1", index: 1, weight: 60, reps: 10),   // 600 kg
                set("s2", index: 2, weight: 60, reps: 8),    // 480 kg
                set("s3", index: 3, weight: 60, reps: 8)     // not completed
            ])],
            completed: ["s1", "s2"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertEqual(summary?.totalVolumeKg, 1080)
        XCTAssertEqual(summary?.completedSets, 2)
        XCTAssertEqual(summary?.totalSets, 3)
    }

    /// A lbs-recorded set must be normalized before it joins a kg total —
    /// otherwise mixed-unit sessions report a wildly inflated volume.
    func testVolumeNormalizesMixedUnitsToKilograms() {
        let live = session(
            exercises: [exercise(sets: [
                set("s1", index: 1, weight: 100, unit: .kg, reps: 1),
                set("s2", index: 2, weight: 100, unit: .lbs, reps: 1)
            ])],
            completed: ["s1", "s2"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        let expected = 100 + 100 * WeightUnit.lbs.toKilogramsFactor
        XCTAssertEqual(summary?.totalVolumeKg ?? 0, expected, accuracy: 0.0001)
    }

    func testBodyweightSetsContributeNoVolumeButStillCount() {
        let live = session(
            exercises: [exercise(name: "Pull Up", sets: [
                set("s1", index: 1, weight: nil, reps: 12)
            ])],
            completed: ["s1"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertEqual(summary?.totalVolumeKg, 0)
        XCTAssertEqual(summary?.completedSets, 1)
        XCTAssertNil(summary?.exercises.first?.bestSetDisplay)
        XCTAssertFalse(summary?.exercises.first?.isNewRecord ?? true)
    }

    // MARK: - PR detection

    func testBeatingPriorRecordFlagsNewRecord() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 100, reps: 3)])],
            completed: ["s1"]
        )
        let priorPRs = [
            "bench press": ExercisePR(
                normalizedName: "bench press",
                displayName: "Bench Press",
                maxWeight: 95,
                weightUnit: .kg,
                achievedAt: Date()
            )
        ]

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: priorPRs, preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertTrue(summary?.exercises.first?.isNewRecord ?? false)
        XCTAssertEqual(summary?.newRecordCount, 1)
    }

    func testMatchingPriorRecordIsNotANewRecord() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 95, reps: 3)])],
            completed: ["s1"]
        )
        let priorPRs = [
            "bench press": ExercisePR(
                normalizedName: "bench press",
                displayName: "Bench Press",
                maxWeight: 95,
                weightUnit: .kg,
                achievedAt: Date()
            )
        ]

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: priorPRs, preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertFalse(summary?.exercises.first?.isNewRecord ?? true)
        XCTAssertEqual(summary?.newRecordCount, 0)
    }

    /// 150 lbs (~68kg) must not beat a 90kg record just because 150 > 90.
    func testPRComparisonNormalizesUnits() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 150, unit: .lbs, reps: 3)])],
            completed: ["s1"]
        )
        let priorPRs = [
            "bench press": ExercisePR(
                normalizedName: "bench press",
                displayName: "Bench Press",
                maxWeight: 90,
                weightUnit: .kg,
                achievedAt: Date()
            )
        ]

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: priorPRs, preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertFalse(summary?.exercises.first?.isNewRecord ?? true)
    }

    /// The exercise name is matched against the PR baseline with the same
    /// trim+lowercase rule `makeExercisePRs` uses, or nothing ever lines up.
    func testPRMatchingIsCaseAndWhitespaceInsensitive() {
        let live = session(
            exercises: [exercise(name: "  BENCH Press ", sets: [set("s1", index: 1, weight: 100, reps: 3)])],
            completed: ["s1"]
        )
        let priorPRs = [
            "bench press": ExercisePR(
                normalizedName: "bench press",
                displayName: "Bench Press",
                maxWeight: 120,
                weightUnit: .kg,
                achievedAt: Date()
            )
        ]

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: priorPRs, preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertFalse(
            summary?.exercises.first?.isNewRecord ?? true,
            "A 100kg set must not be a PR against a 120kg record that differs only in case/whitespace"
        )
    }

    func testFirstEverPerformanceCountsAsRecord() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 40, reps: 10)])],
            completed: ["s1"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertTrue(summary?.exercises.first?.isNewRecord ?? false)
    }

    /// A nil baseline means "we could not read history" — claiming a PR there
    /// would be a guess, so PR callouts are suppressed entirely.
    func testUnavailableBaselineSuppressesRecordClaims() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 300, reps: 10)])],
            completed: ["s1"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: nil, preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertEqual(summary?.newRecordCount, 0)
        XCTAssertEqual(summary?.totalVolumeKg, 3000, "Volume is still reported without a PR baseline")
    }

    // MARK: - Best set

    func testBestSetPicksHeaviestCompletedSetAcrossUnits() {
        let live = session(
            exercises: [exercise(sets: [
                set("s1", index: 1, weight: 60, unit: .kg, reps: 10),
                set("s2", index: 2, weight: 200, unit: .lbs, reps: 5),   // ~90.7kg — heaviest
                set("s3", index: 3, weight: 80, unit: .kg, reps: 6)
            ])],
            completed: ["s1", "s2", "s3"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertEqual(summary?.exercises.first?.bestSetDisplay, "200 lbs × 5")
    }

    func testBestSetIgnoresUncompletedHeavierSet() {
        let live = session(
            exercises: [exercise(sets: [
                set("s1", index: 1, weight: 60, reps: 10),
                set("s2", index: 2, weight: 200, reps: 1)   // planned but never done
            ])],
            completed: ["s1"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertEqual(summary?.exercises.first?.bestSetDisplay, "60 kg × 10")
        XCTAssertEqual(summary?.exercises.first?.bestWeightKg, 60)
    }

    // MARK: - Duration / empty

    func testDurationDerivesFromStartedAt() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 60, reps: 8)])],
            completed: ["s1"],
            startedAt: start
        )

        let summary = TrainingSessionSummary.make(
            session: live,
            priorPRs: [:],
            preferredUnit: .kg,
            endedAt: start.addingTimeInterval(3727)   // 1h 2m 7s
        )

        XCTAssertEqual(summary?.durationSeconds, 3727)
        XCTAssertEqual(summary?.durationDisplay, "1:02:07")
    }

    /// Sessions restored from a build that predates `startedAt` have no start
    /// time; the summary must still render, just without a duration tile.
    func testMissingStartedAtYieldsNoDuration() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 60, reps: 8)])],
            completed: ["s1"],
            startedAt: nil
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertNotNil(summary)
        XCTAssertNil(summary?.durationSeconds)
        XCTAssertNil(summary?.durationDisplay)
    }

    func testShortDurationFormatsWithoutHours() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 60, reps: 8)])],
            completed: ["s1"],
            startedAt: start
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: start.addingTimeInterval(2527)
        )

        XCTAssertEqual(summary?.durationDisplay, "42:07")
    }

    func testSessionWithNoCompletedSetsHasNoSummary() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 60, reps: 8)])],
            completed: []
        )

        XCTAssertNil(TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        ))
    }

    // MARK: - Skipped

    func testPartiallyDoneSkippedExerciseIsMarkedSkipped() {
        let live = session(
            exercises: [exercise(sets: [
                set("s1", index: 1, weight: 60, reps: 8),
                set("s2", index: 2, weight: 60, reps: 8)
            ])],
            completed: ["s1"],
            skipped: ["e1"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertTrue(summary?.exercises.first?.wasSkipped ?? false)
    }

    /// Skipping and then coming back to finish every set means it wasn't
    /// skipped in the end — the summary should not say otherwise.
    func testFullyCompletedExerciseIsNotMarkedSkipped() {
        let live = session(
            exercises: [exercise(sets: [
                set("s1", index: 1, weight: 60, reps: 8),
                set("s2", index: 2, weight: 60, reps: 8)
            ])],
            completed: ["s1", "s2"],
            skipped: ["e1"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertFalse(summary?.exercises.first?.wasSkipped ?? true)
    }

    // MARK: - Volume display

    func testVolumeDisplayFollowsPreferredUnit() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 100, reps: 5)])],
            completed: ["s1"]
        )

        let kg = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )
        let lbs = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .lbs, endedAt: Date()
        )

        XCTAssertEqual(kg?.volumeDisplay, "500kg")
        XCTAssertEqual(lbs?.volumeDisplay, "1.1k lbs")
    }

    func testLargeKilogramVolumeFoldsIntoTonnes() {
        let live = session(
            exercises: [exercise(sets: [set("s1", index: 1, weight: 100, reps: 32)])],
            completed: ["s1"]
        )

        let summary = TrainingSessionSummary.make(
            session: live, priorPRs: [:], preferredUnit: .kg, endedAt: Date()
        )

        XCTAssertEqual(summary?.volumeDisplay, "3.2t")
    }
}
