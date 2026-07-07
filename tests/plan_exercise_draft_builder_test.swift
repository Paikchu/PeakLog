import Foundation

@main
struct PlanExerciseDraftBuilderTestRunner {
    static func main() {
        buildsDraftsWithMultipleExercisesAndPerSetTargets()
        preservesOptionalAddedWeightForBodyweightExercises()
        rejectsIncompleteForms()
        print("plan_exercise_draft_builder_test passed")
    }

    private static func buildsDraftsWithMultipleExercisesAndPerSetTargets() {
        let exercises = [
            DailyRecordExerciseInput(name: "卧推", sets: [
                DailyRecordSetInput(weight: 60, reps: 12),
                DailyRecordSetInput(weight: 70, reps: 10),
                DailyRecordSetInput(weight: 75, reps: 8),
            ]),
            DailyRecordExerciseInput(name: " 深蹲 ", sets: [
                DailyRecordSetInput(weight: 100, reps: 5),
            ]),
        ]

        guard let drafts = PlanExerciseDraftBuilder.drafts(exercises: exercises) else {
            preconditionFailure("Expected valid drafts for two complete exercises")
        }

        precondition(drafts.count == 2, "Expected 2 drafts, got \(drafts.count)")
        precondition(drafts[0].exerciseName == "卧推")
        precondition(drafts[0].isBodyweight == false)
        precondition(drafts[0].sets.map(\.targetWeight) == [60, 70, 75], "Expected per-set target weights preserved")
        precondition(drafts[0].sets.map(\.targetReps) == [12, 10, 8], "Expected per-set target reps preserved")
        precondition(drafts[1].exerciseName == "深蹲", "Exercise name should be trimmed")
    }

    /// A bodyweight exercise (e.g. weighted pull-ups) can mix pure-bodyweight
    /// sets with sets that add extra weight on top; nil still means no added
    /// weight, but a positive value must survive the draft builder.
    private static func preservesOptionalAddedWeightForBodyweightExercises() {
        let exercises = [
            DailyRecordExerciseInput(name: "引体向上", isBodyweight: true, sets: [
                DailyRecordSetInput(weight: 20, reps: 10),
                DailyRecordSetInput(weight: nil, reps: 8),
            ]),
        ]

        guard let drafts = PlanExerciseDraftBuilder.drafts(exercises: exercises) else {
            preconditionFailure("Expected bodyweight exercise without weights to be valid")
        }

        precondition(drafts[0].isBodyweight)
        precondition(drafts[0].sets.map(\.targetWeight) == [20, nil], "Added weight on a bodyweight set must be preserved")
        precondition(drafts[0].sets.map(\.targetReps) == [10, 8])
    }

    private static func rejectsIncompleteForms() {
        precondition(PlanExerciseDraftBuilder.drafts(exercises: []) == nil, "Expected nil for empty exercise list")

        let emptyName = [DailyRecordExerciseInput(name: "  ", sets: [DailyRecordSetInput(weight: 60, reps: 10)])]
        precondition(PlanExerciseDraftBuilder.drafts(exercises: emptyName) == nil, "Expected nil when a name is blank")

        let missingWeight = [DailyRecordExerciseInput(name: "卧推", sets: [
            DailyRecordSetInput(weight: 60, reps: 10),
            DailyRecordSetInput(weight: nil, reps: 10),
        ])]
        precondition(PlanExerciseDraftBuilder.drafts(exercises: missingWeight) == nil, "Expected nil when a weighted set has no weight")

        let zeroReps = [DailyRecordExerciseInput(name: "卧推", sets: [DailyRecordSetInput(weight: 60, reps: 0)])]
        precondition(PlanExerciseDraftBuilder.drafts(exercises: zeroReps) == nil, "Expected nil when a set has zero reps")
    }
}
