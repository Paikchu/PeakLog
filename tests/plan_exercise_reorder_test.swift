import Foundation

@main
struct PlanExerciseReorderTestRunner {
    static func main() {
        reordersExercisesAndRenumbersOrderIndex()
        rejectsMismatchedIdSet()
        rejectsWrongCount()
        rejectsDuplicateIds()
        preservesExerciseFieldsAndSets()
        handlesSingleExercise()
        print("plan_exercise_reorder_test passed")
    }

    private static func makeExercise(id: String, orderIndex: Int, name: String) -> TrainingPlanExercise {
        TrainingPlanExercise(
            id: id,
            orderIndex: orderIndex,
            exerciseName: name,
            exerciseId: nil,
            exerciseLoadType: .weighted,
            progressionMode: "manual",
            notes: "note-\(id)",
            previousPerformanceSummary: nil,
            aiSuggestion: "suggestion-\(id)",
            sets: [
                TrainingPlanSet(
                    id: "set-\(id)",
                    setIndex: 1,
                    targetWeight: 60,
                    targetWeightUnit: .kg,
                    targetReps: 10,
                    completedAt: nil,
                    linkedExerciseSetId: nil
                ),
            ]
        )
    }

    private static func makeDay(_ exercises: [TrainingPlanExercise]) -> TrainingPlanDay {
        TrainingPlanDay(
            id: "day-1",
            planDate: "2026-07-06",
            dayIndex: 1,
            title: "Test Day",
            focus: nil,
            status: "planned",
            exercises: exercises
        )
    }

    private static func reordersExercisesAndRenumbersOrderIndex() {
        let a = makeExercise(id: "a", orderIndex: 0, name: "Bench")
        let b = makeExercise(id: "b", orderIndex: 1, name: "Squat")
        let c = makeExercise(id: "c", orderIndex: 2, name: "Deadlift")
        let day = makeDay([a, b, c])

        guard let reordered = day.reordered(byExerciseIds: ["c", "a", "b"]) else {
            preconditionFailure("Expected valid reorder for a permutation of existing ids")
        }

        precondition(reordered.exercises.map(\.id) == ["c", "a", "b"], "Expected exercises in requested order")
        precondition(reordered.exercises.map(\.orderIndex) == [0, 1, 2], "Expected orderIndex renumbered to 0..<count")
    }

    private static func rejectsMismatchedIdSet() {
        let a = makeExercise(id: "a", orderIndex: 0, name: "Bench")
        let b = makeExercise(id: "b", orderIndex: 1, name: "Squat")
        let day = makeDay([a, b])

        precondition(day.reordered(byExerciseIds: ["a", "z"]) == nil, "Expected nil when an unknown id is included")
    }

    private static func rejectsWrongCount() {
        let a = makeExercise(id: "a", orderIndex: 0, name: "Bench")
        let b = makeExercise(id: "b", orderIndex: 1, name: "Squat")
        let day = makeDay([a, b])

        precondition(day.reordered(byExerciseIds: ["a"]) == nil, "Expected nil when fewer ids than exercises are provided")
        precondition(day.reordered(byExerciseIds: ["a", "b", "a"]) == nil, "Expected nil when more ids than exercises are provided")
    }

    private static func rejectsDuplicateIds() {
        let a = makeExercise(id: "a", orderIndex: 0, name: "Bench")
        let b = makeExercise(id: "b", orderIndex: 1, name: "Squat")
        let day = makeDay([a, b])

        precondition(day.reordered(byExerciseIds: ["a", "a"]) == nil, "Expected nil when the same id repeats instead of covering all exercises")
    }

    private static func preservesExerciseFieldsAndSets() {
        let a = makeExercise(id: "a", orderIndex: 0, name: "Bench")
        let b = makeExercise(id: "b", orderIndex: 1, name: "Squat")
        let day = makeDay([a, b])

        guard let reordered = day.reordered(byExerciseIds: ["b", "a"]) else {
            preconditionFailure("Expected valid reorder")
        }

        let movedA = reordered.exercises.first { $0.id == "a" }
        precondition(movedA?.notes == "note-a", "Expected notes preserved across reorder")
        precondition(movedA?.aiSuggestion == "suggestion-a", "Expected aiSuggestion preserved across reorder")
        precondition(movedA?.sets.map(\.id) == ["set-a"], "Expected sets preserved across reorder")
    }

    private static func handlesSingleExercise() {
        let a = makeExercise(id: "a", orderIndex: 0, name: "Bench")
        let day = makeDay([a])

        guard let reordered = day.reordered(byExerciseIds: ["a"]) else {
            preconditionFailure("Expected valid reorder for a single exercise")
        }
        precondition(reordered.exercises.map(\.id) == ["a"])
        precondition(reordered.exercises.map(\.orderIndex) == [0])
    }
}
