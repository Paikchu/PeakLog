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

    func testPlanCompletionWithoutLoggedSetIsClearedWhenCloudStateLoads() async throws {
        let databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-completion-sanitize-\(UUID().uuidString).json")
        let database = LocalAppDatabase(fileURL: databaseFileURL)
        defer { try? FileManager.default.removeItem(at: databaseFileURL) }

        let snapshot = await database.snapshot()
        var dirtyPlan = snapshot.activePlan
        dirtyPlan.days[0].exercises[0].sets[0].completedAt = Date()
        dirtyPlan.days[0].exercises[0].sets[0].linkedExerciseSetId = "missing-set"

        await database.replaceAll(
            profile: snapshot.profile,
            activePlan: dirtyPlan,
            strengthSessions: [],
            runningRecords: [],
            customExercises: snapshot.customExercises,
            goalSpec: snapshot.goalSpec
        )

        let maybeLoadedPlan = await database.activePlan()
        let loadedPlan = try XCTUnwrap(maybeLoadedPlan)
        XCTAssertFalse(loadedPlan.days[0].exercises[0].sets[0].isCompleted)
        XCTAssertNil(loadedPlan.days[0].exercises[0].sets[0].linkedExerciseSetId)
    }

    func testPlanCompletionWithLoggedSetSurvivesCloudStateLoad() async throws {
        let databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-completion-preserve-\(UUID().uuidString).json")
        let database = LocalAppDatabase(fileURL: databaseFileURL)
        defer { try? FileManager.default.removeItem(at: databaseFileURL) }

        let snapshot = await database.snapshot()
        var completedPlan = snapshot.activePlan
        let planDay = completedPlan.days[0]
        let planExercise = planDay.exercises[0]
        completedPlan.days[0].exercises[0].sets[0].completedAt = Date()
        completedPlan.days[0].exercises[0].sets[0].linkedExerciseSetId = "logged-set"

        let sessionDate = WorkoutDateFormatter().date(from: planDay.planDate) ?? Date()
        let session = WorkoutSession(
            id: UUID().uuidString,
            userId: snapshot.profile.id,
            date: sessionDate,
            durationMinutes: nil,
            label: planDay.title,
            exercises: [
                Exercise(
                    id: UUID().uuidString,
                    name: planExercise.exerciseName,
                    exerciseId: planExercise.exerciseId,
                    exerciseLoadType: planExercise.exerciseLoadType,
                    sets: [
                        ExerciseSet(
                            id: "logged-set",
                            setIndex: 1,
                            weight: 60,
                            weightUnit: .kg,
                            reps: 8,
                            rpe: nil
                        )
                    ]
                )
            ],
            createdAt: Date(),
            updatedAt: Date()
        )

        await database.replaceAll(
            profile: snapshot.profile,
            activePlan: completedPlan,
            strengthSessions: [session],
            runningRecords: [],
            customExercises: snapshot.customExercises,
            goalSpec: snapshot.goalSpec
        )

        let maybeLoadedPlan = await database.activePlan()
        let loadedPlan = try XCTUnwrap(maybeLoadedPlan)
        XCTAssertTrue(loadedPlan.days[0].exercises[0].sets[0].isCompleted)
        XCTAssertEqual(loadedPlan.days[0].exercises[0].sets[0].linkedExerciseSetId, "logged-set")
    }
}
