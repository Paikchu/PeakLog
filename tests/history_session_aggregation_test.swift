import Foundation

@main
struct HistorySessionAggregationTestRunner {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_763_545_200)
        let day = ISO8601DateFormatter().date(from: "2026-03-19T00:00:00Z") ?? now

        let morningSession = WorkoutSession(
            id: "session-1",
            userId: "user-1",
            date: day,
            durationMinutes: 20,
            label: "Morning",
            exercises: [
                Exercise(
                    id: "bench-1",
                    name: "bench press",
                    sets: [
                        ExerciseSet(id: "set-1", setIndex: 1, weight: 80, weightUnit: .kg, reps: 10),
                        ExerciseSet(id: "set-2", setIndex: 2, weight: 80, weightUnit: .kg, reps: 10),
                    ]
                ),
                Exercise(
                    id: "squat-1",
                    name: "squats",
                    sets: [
                        ExerciseSet(id: "set-3", setIndex: 1, weight: 100, weightUnit: .kg, reps: 8)
                    ]
                )
            ],
            createdAt: now,
            updatedAt: now
        )

        let eveningSession = WorkoutSession(
            id: "session-2",
            userId: "user-1",
            date: day,
            durationMinutes: 30,
            label: "Evening",
            exercises: [
                Exercise(
                    id: "bench-2",
                    name: "bench press",
                    sets: [
                        ExerciseSet(id: "set-4", setIndex: 1, weight: 82.5, weightUnit: .kg, reps: 8)
                    ]
                ),
                Exercise(
                    id: "deadlift-1",
                    name: "deadlifts",
                    sets: [
                        ExerciseSet(id: "set-5", setIndex: 1, weight: 60, weightUnit: .kg, reps: 5)
                    ]
                )
            ],
            createdAt: now.addingTimeInterval(3600),
            updatedAt: now.addingTimeInterval(3600)
        )

        let merged = WorkoutHistoryAggregator.mergeSessionsForHistory([morningSession, eveningSession])

        precondition(merged.count == 1, "Expected one merged history card, got \(merged.count)")
        let session = merged[0]
        precondition(session.durationMinutes == 50, "Expected combined duration to be 50, got \(String(describing: session.durationMinutes))")
        precondition(session.exercises.count == 3, "Expected 3 merged exercises, got \(session.exercises.count)")

        let exerciseNames = session.exercises.map { $0.name }
        precondition(exerciseNames == ["bench press", "squats", "deadlifts"], "Unexpected exercise order: \(exerciseNames)")

        let bench = session.exercises[0]
        precondition(bench.sets.count == 3, "Expected merged bench press sets, got \(bench.sets.count)")
        precondition(bench.sets.map { $0.setIndex } == [1, 2, 3], "Expected bench set indexes to be renumbered, got \(bench.sets.map { $0.setIndex })")
        precondition(bench.sets.map { $0.weight } == [80, 80, 82.5], "Unexpected merged bench weights: \(bench.sets.map { $0.weight })")

        print("history_session_aggregation_test passed")
    }
}
