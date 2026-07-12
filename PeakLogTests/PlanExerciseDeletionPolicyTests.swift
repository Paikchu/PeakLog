import XCTest
@testable import PeakLog

final class PlanExerciseDeletionPolicyTests: XCTestCase {
    func testUncompletedExerciseCanDeleteImmediately() {
        let exercise = makeExercise(completed: false)

        XCTAssertFalse(PlanExerciseDeletionPolicy.requiresConfirmation(for: exercise))
    }

    func testCompletedExerciseRequiresConfirmationAndReportsCascadeImpact() {
        let exercise = makeExercise(completed: true)

        XCTAssertTrue(PlanExerciseDeletionPolicy.requiresConfirmation(for: exercise))
        XCTAssertEqual(PlanExerciseDeletionPolicy.completedSetCount(for: exercise), 2)
    }

    private func makeExercise(completed: Bool) -> TrainingPlanExercise {
        TrainingPlanExercise(
            id: "exercise-1",
            orderIndex: 0,
            exerciseName: "Bench Press",
            exerciseLoadType: .weighted,
            progressionMode: "double_progression",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: (0..<2).map { index in
                TrainingPlanSet(
                    id: "set-\(index)",
                    setIndex: index,
                    targetWeight: 60,
                    targetWeightUnit: .kg,
                    targetReps: 8,
                    completedAt: completed ? Date() : nil,
                    linkedExerciseSetId: completed ? "logged-set-\(index)" : nil
                )
            }
        )
    }
}
