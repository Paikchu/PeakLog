import Foundation

enum MockData {
    static let benchPress = Exercise(
        id: "mock-ex-bench",
        name: "Bench Press",
        sets: [
            ExerciseSet(id: "mock-set-bench-1", setIndex: 1, weight: 80, weightUnit: .kg, reps: 10, rpe: nil),
            ExerciseSet(id: "mock-set-bench-2", setIndex: 2, weight: 80, weightUnit: .kg, reps: 10, rpe: nil),
            ExerciseSet(id: "mock-set-bench-3", setIndex: 3, weight: 82.5, weightUnit: .kg, reps: 8, rpe: nil)
        ]
    )

    static let squat = Exercise(
        id: "mock-ex-squat",
        name: "Squat",
        sets: [
            ExerciseSet(id: "mock-set-squat-1", setIndex: 1, weight: 100, weightUnit: .kg, reps: 8, rpe: nil),
            ExerciseSet(id: "mock-set-squat-2", setIndex: 2, weight: 100, weightUnit: .kg, reps: 8, rpe: nil),
            ExerciseSet(id: "mock-set-squat-3", setIndex: 3, weight: 100, weightUnit: .kg, reps: 8, rpe: nil)
        ]
    )

    static let deadlift = Exercise(
        id: "mock-ex-deadlift",
        name: "Deadlift",
        sets: [
            ExerciseSet(id: "mock-set-deadlift-1", setIndex: 1, weight: 120, weightUnit: .kg, reps: 5, rpe: nil)
        ]
    )

    static var sampleExercises: [Exercise] {
        [benchPress, squat, deadlift]
    }
}
