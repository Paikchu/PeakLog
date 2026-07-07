import Foundation

@main
struct DailyRecordMultiExerciseDraftTestRunner {
    static func main() {
        buildsDraftWithMultipleExercisesAndPerSetValues()
        preservesOptionalAddedWeightForBodyweightExercises()
        rejectsIncompleteForms()
        copiesLastSetWhenAppending()
        trimsTitleAndDropsEmptyOne()
        print("daily_record_multi_exercise_draft_test passed")
    }

    private static func buildsDraftWithMultipleExercisesAndPerSetValues() {
        let exercises = [
            DailyRecordExerciseInput(name: "卧推", sets: [
                DailyRecordSetInput(weight: 60, reps: 12),
                DailyRecordSetInput(weight: 70, reps: 10),
                DailyRecordSetInput(weight: 75, reps: 8),
            ]),
            DailyRecordExerciseInput(name: "深蹲", sets: [
                DailyRecordSetInput(weight: 100, reps: 5),
            ]),
        ]

        guard let draft = DailyRecordDraftBuilder.strengthDraft(title: "推力日", workoutDate: Date(), exercises: exercises) else {
            preconditionFailure("Expected a valid draft for two complete exercises")
        }

        precondition(draft.exercises.count == 2, "Expected 2 exercises, got \(draft.exercises.count)")
        precondition(draft.exercises[0].name == "卧推")
        precondition(draft.exercises[0].sets.map(\.weight) == [60, 70, 75], "Expected per-set weights preserved")
        precondition(draft.exercises[0].sets.map(\.reps) == [12, 10, 8], "Expected per-set reps preserved")
        precondition(draft.exercises[1].sets.count == 1)
        precondition(draft.exercises[1].sets[0].weight == 100)
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

        guard let draft = DailyRecordDraftBuilder.strengthDraft(title: "", workoutDate: Date(), exercises: exercises) else {
            preconditionFailure("Expected bodyweight exercise without weights to be valid")
        }

        precondition(draft.exercises[0].sets.map(\.weight) == [20, nil], "Added weight on a bodyweight set must be preserved")
        precondition(draft.exercises[0].sets.map(\.reps) == [10, 8])
    }

    private static func rejectsIncompleteForms() {
        let emptyName = [DailyRecordExerciseInput(name: "  ", sets: [DailyRecordSetInput(weight: 60, reps: 10)])]
        precondition(
            DailyRecordDraftBuilder.strengthDraft(title: "", workoutDate: Date(), exercises: emptyName) == nil,
            "Expected nil draft when an exercise name is blank"
        )

        let missingWeight = [DailyRecordExerciseInput(name: "卧推", sets: [
            DailyRecordSetInput(weight: 60, reps: 10),
            DailyRecordSetInput(weight: nil, reps: 10),
        ])]
        precondition(
            DailyRecordDraftBuilder.strengthDraft(title: "", workoutDate: Date(), exercises: missingWeight) == nil,
            "Expected nil draft when a weighted set has no weight"
        )

        let zeroReps = [DailyRecordExerciseInput(name: "卧推", sets: [DailyRecordSetInput(weight: 60, reps: 0)])]
        precondition(
            DailyRecordDraftBuilder.strengthDraft(title: "", workoutDate: Date(), exercises: zeroReps) == nil,
            "Expected nil draft when a set has zero reps"
        )

        precondition(
            DailyRecordDraftBuilder.strengthDraft(title: "", workoutDate: Date(), exercises: []) == nil,
            "Expected nil draft when no exercise exists"
        )
    }

    private static func copiesLastSetWhenAppending() {
        var exercise = DailyRecordExerciseInput(name: "卧推", sets: [DailyRecordSetInput(weight: 70, reps: 10)])
        exercise.appendSetCopyingLast()

        precondition(exercise.sets.count == 2)
        precondition(exercise.sets[1].weight == 70, "New set should copy the previous set's weight")
        precondition(exercise.sets[1].reps == 10, "New set should copy the previous set's reps")
        precondition(exercise.sets[0].id != exercise.sets[1].id, "Copied set must get its own identity")

        exercise.removeLastSet()
        exercise.removeLastSet()
        precondition(exercise.sets.count == 1, "removeLastSet must keep at least one set")
    }

    private static func trimsTitleAndDropsEmptyOne() {
        let exercises = [DailyRecordExerciseInput(name: "卧推", sets: [DailyRecordSetInput(weight: 60, reps: 10)])]

        let blankTitle = DailyRecordDraftBuilder.strengthDraft(title: "   ", workoutDate: Date(), exercises: exercises)
        precondition(blankTitle?.title == nil, "Blank title should map to nil")

        let padded = DailyRecordDraftBuilder.strengthDraft(title: " 推力日 ", workoutDate: Date(), exercises: exercises)
        precondition(padded?.title == "推力日", "Title should be trimmed")
    }
}
