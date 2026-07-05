import XCTest
@testable import PeakLog

final class PeakLogSmokeTests: XCTestCase {
    func testWorkoutHistoryAggregatorMergesSessionsForHistory() {
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
                        ExerciseSet(id: "set-3", setIndex: 1, weight: 82.5, weightUnit: .kg, reps: 8),
                    ]
                ),
            ],
            createdAt: now.addingTimeInterval(3600),
            updatedAt: now.addingTimeInterval(3600)
        )

        let merged = WorkoutHistoryAggregator.mergeSessionsForHistory([morningSession, eveningSession])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].durationMinutes, 50)
        XCTAssertEqual(merged[0].exercises.count, 1)
        XCTAssertEqual(merged[0].exercises[0].sets.map(\.setIndex), [1, 2, 3])
    }
}
