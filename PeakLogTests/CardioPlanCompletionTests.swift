import XCTest
@testable import PeakLog

final class CardioPlanCompletionTests: XCTestCase {
    func testManualAddCreatesCardioPlanItemWithoutStrengthSets() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-cardio-manual-add-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let database = LocalAppDatabase(fileURL: fileURL)
        let draft = try PlanExerciseDraft.cardio(
            activityType: .cycling,
            targetDurationMinutes: 40,
            targetDistanceKm: 15,
            targetRPE: 6
        )

        let day = try await database.addPlannedExercises([draft])
        let item = try XCTUnwrap(day.exercises.last)

        XCTAssertEqual(item.itemType, .cardio)
        XCTAssertEqual(item.cardioActivityType, .cycling)
        XCTAssertEqual(item.targetDurationMinutes, 40)
        XCTAssertEqual(item.targetDistanceKm, 15)
        XCTAssertEqual(item.targetRPE, 6)
        XCTAssertTrue(item.sets.isEmpty)
        XCTAssertEqual(item.exerciseLoadType, .unknown)
    }

    func testCompletionCreatesOneRecordAndLinksPlanItem() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-cardio-completion-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let database = LocalAppDatabase(fileURL: fileURL)
        let initial = await database.snapshot()
        let item = TrainingPlanExercise(
            id: UUID().uuidString,
            orderIndex: 0,
            exerciseName: "Cycling",
            exerciseLoadType: .unknown,
            progressionMode: "maintain",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: [],
            itemType: .cardio,
            cardioActivityType: .cycling,
            targetDurationMinutes: 30,
            targetDistanceKm: 10,
            targetRPE: 6
        )
        let plan = TrainingPlan(
            id: initial.activePlan.id,
            weekStartDate: initial.activePlan.weekStartDate,
            goalSummary: initial.activePlan.goalSummary,
            coachSummary: initial.activePlan.coachSummary,
            days: [TrainingPlanDay(
                id: UUID().uuidString,
                planDate: WorkoutDateFormatter().string(from: Date()),
                dayIndex: 0,
                title: "Cardio",
                focus: "Aerobic base",
                status: "planned",
                exercises: [item]
            )]
        )
        await database.replaceAll(
            profile: initial.profile,
            activePlan: plan,
            strengthSessions: initial.strengthSessions,
            runningRecords: [],
            customExercises: initial.customExercises,
            goalSpec: initial.goalSpec
        )

        let metrics = try CardioMetrics(
            activityType: .cycling,
            durationMinutes: 32,
            distanceKm: 11.5,
            rpe: 7
        )
        let record = try await database.completePlannedCardio(planExerciseId: item.id, metrics: metrics)
        let after = await database.snapshot()

        XCTAssertEqual(after.runningRecords, [record])
        XCTAssertEqual(after.activePlan.days[0].exercises[0].linkedCardioWorkoutId, record.id)
        XCTAssertNotNil(after.activePlan.days[0].exercises[0].cardioCompletedAt)

        do {
            _ = try await database.completePlannedCardio(planExerciseId: item.id, metrics: metrics)
            XCTFail("Expected duplicate completion to fail")
        } catch LocalAppDatabaseError.cardioAlreadyCompleted {
            let duplicateSnapshot = await database.snapshot()
            XCTAssertEqual(duplicateSnapshot.runningRecords.count, 1)
        }
    }
}
