import XCTest
@testable import PeakLog

/// Covers the dock CTA's state machine — in particular the reported bug where a
/// day already badged "✓ Done" still offered a full-width "Start Training".
///
/// `@MainActor` because `TrainingActionLayer.State` is nested in a SwiftUI view
/// and picks up the target's default main-actor isolation.
@MainActor
final class TrainingActionLayerStateTests: XCTestCase {
    private func resolve(
        isTrainingFocusVisible: Bool = false,
        activeSessionProgress: (completed: Int, total: Int)? = nil,
        isSelectedDateToday: Bool = true,
        hasPlanSets: Bool = true,
        hasPendingStrengthSets: Bool = true,
        hasSessionSummary: Bool = false
    ) -> TrainingActionLayer.State? {
        TrainingActionLayer.State.resolve(
            isTrainingFocusVisible: isTrainingFocusVisible,
            activeSessionProgress: activeSessionProgress,
            isSelectedDateToday: isSelectedDateToday,
            hasPlanSets: hasPlanSets,
            hasPendingStrengthSets: hasPendingStrengthSets,
            hasSessionSummary: hasSessionSummary
        )
    }

    func testTodayWithPendingSetsOffersStart() {
        XCTAssertEqual(resolve(), .start)
    }

    /// The bug: with every strength set done, the primary CTA used to stay.
    func testCompletedDayNoLongerOffersStart() {
        XCTAssertNil(resolve(hasPendingStrengthSets: false))
    }

    func testCompletedDayWithSummaryOffersSummaryEntryPoint() {
        XCTAssertEqual(
            resolve(hasPendingStrengthSets: false, hasSessionSummary: true),
            .summary
        )
    }

    /// A summary from an earlier finish must not outrank work still to do.
    func testPendingSetsOutrankAnExistingSummary() {
        XCTAssertEqual(resolve(hasPendingStrengthSets: true, hasSessionSummary: true), .start)
    }

    func testActiveSessionShowsResumeFromAnyDate() {
        XCTAssertEqual(
            resolve(activeSessionProgress: (completed: 3, total: 15), isSelectedDateToday: false),
            .resume(completed: 3, total: 15)
        )
    }

    /// Resume wins over start: the running session is the thing to get back to.
    func testActiveSessionOutranksStart() {
        XCTAssertEqual(
            resolve(activeSessionProgress: (completed: 1, total: 10)),
            .resume(completed: 1, total: 10)
        )
    }

    func testFocusModeHidesTheLayerEntirely() {
        XCTAssertNil(resolve(isTrainingFocusVisible: true))
        XCTAssertNil(resolve(
            isTrainingFocusVisible: true,
            activeSessionProgress: (completed: 1, total: 5)
        ))
    }

    func testPastOrFutureDateOffersNothingWithoutASession() {
        XCTAssertNil(resolve(isSelectedDateToday: false))
        XCTAssertNil(resolve(isSelectedDateToday: false, hasPendingStrengthSets: false, hasSessionSummary: true))
    }

    func testRestDayWithNoPlannedSetsOffersNothing() {
        XCTAssertNil(resolve(hasPlanSets: false))
        XCTAssertNil(resolve(hasPlanSets: false, hasPendingStrengthSets: false, hasSessionSummary: true))
    }
}

/// `TrainingPlanDay.hasPendingStrengthSets` is what feeds the resolver above.
final class TrainingPlanDayPendingStrengthTests: XCTestCase {
    private func day(exercises: [TrainingPlanExercise]) -> TrainingPlanDay {
        TrainingPlanDay(
            id: "day",
            planDate: "2026-08-05",
            dayIndex: 1,
            title: "Push",
            focus: nil,
            status: "planned",
            exercises: exercises
        )
    }

    private func strength(id: String, completed: [Bool]) -> TrainingPlanExercise {
        TrainingPlanExercise(
            id: id,
            orderIndex: 0,
            exerciseName: "Bench Press",
            exerciseLoadType: .weighted,
            progressionMode: "weight_first",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: completed.enumerated().map { index, isDone in
                TrainingPlanSet(
                    id: "\(id)-s\(index)",
                    setIndex: index + 1,
                    targetWeight: 60,
                    targetWeightUnit: .kg,
                    targetReps: 8,
                    completedAt: isDone ? Date() : nil,
                    linkedExerciseSetId: nil
                )
            }
        )
    }

    private func cardio(id: String, completedAt: Date?) -> TrainingPlanExercise {
        TrainingPlanExercise(
            id: id,
            orderIndex: 1,
            exerciseName: "Run",
            exerciseLoadType: .unknown,
            progressionMode: "duration_first",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: [],
            itemType: .cardio,
            cardioCompletedAt: completedAt
        )
    }

    func testPendingWhenAnySetIsIncomplete() {
        XCTAssertTrue(day(exercises: [strength(id: "e1", completed: [true, false])]).hasPendingStrengthSets)
    }

    func testNotPendingWhenEverySetIsDone() {
        XCTAssertFalse(day(exercises: [strength(id: "e1", completed: [true, true])]).hasPendingStrengthSets)
    }

    /// Focus mode only runs strength work, so an unfinished cardio item is not
    /// something "Start Training" could act on.
    func testUnfinishedCardioDoesNotCountAsPendingStrength() {
        let plan = day(exercises: [
            strength(id: "e1", completed: [true, true]),
            cardio(id: "e2", completedAt: nil)
        ])
        XCTAssertFalse(plan.hasPendingStrengthSets)
    }

    func testEmptyPlanIsNotPending() {
        XCTAssertFalse(day(exercises: []).hasPendingStrengthSets)
    }
}
