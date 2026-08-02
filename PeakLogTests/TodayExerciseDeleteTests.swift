import XCTest
@testable import PeakLog

/// 覆盖「今日计划/记录动作滑动删除」的数据层与状态层行为。
@MainActor
final class TodayExerciseDeleteTests: XCTestCase {
    private var databaseFileURL: URL!
    private var database: LocalAppDatabase!

    // `setUp()`/`tearDown()` are the `async throws` variants, not the sync ones:
    // the sync overrides are nonisolated on `XCTestCase`, so a `@MainActor` test
    // case cannot touch its own main-actor properties in them under the Swift 6
    // language mode. The async variants may carry the class's isolation
    // (issue #137).
    override func setUp() async throws {
        try await super.setUp()
        databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("today-exercise-delete-tests-\(UUID().uuidString).json")
        database = LocalAppDatabase(fileURL: databaseFileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: databaseFileURL)
        try await super.tearDown()
    }

    // 已完成的计划动作也能删除，且落库的记录被级联删除，不留孤儿记录。
    func testDeletingCompletedPlanExerciseCascadesLinkedRecords() async throws {
        let day = try await database.addPlannedExercises([
            PlanExerciseDraft(
                exerciseName: "Cascade Bench",
                isBodyweight: false,
                sets: [
                    PlanExerciseDraft.SetDraft(targetWeight: 60, targetWeightUnit: .kg, targetReps: 8),
                    PlanExerciseDraft.SetDraft(targetWeight: 60, targetWeightUnit: .kg, targetReps: 8)
                ]
            )
        ])
        let exercise = try XCTUnwrap(day.exercises.first { $0.exerciseName == "Cascade Bench" })

        for set in exercise.sets {
            _ = try await database.completePlannedSet(
                planSetId: set.id,
                actualWeight: set.targetWeight,
                actualWeightUnit: set.targetWeightUnit,
                actualReps: set.targetReps
            )
        }
        let sessionsBefore = await database.sessionsForDay(Date())
        XCTAssertTrue(
            sessionsBefore.flatMap(\.exercises).contains { $0.name == "Cascade Bench" },
            "完成组应已落库为训练记录"
        )

        try await database.deletePlannedExercise(planExerciseId: exercise.id)

        let planAfter = await database.todayPlan()
        XCTAssertFalse(planAfter?.exercises.contains { $0.id == exercise.id } ?? false)
        let sessionsAfter = await database.sessionsForDay(Date())
        XCTAssertFalse(
            sessionsAfter.flatMap(\.exercises).contains { $0.name == "Cascade Bench" },
            "删除计划动作应级联删除其关联记录"
        )
    }

    // 删除记录动作时移除整个动作，session 清空则一并移除。
    func testDeletingLoggedExerciseRemovesExerciseAndEmptySession() async throws {
        let session = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Free Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Free Squat",
                    sets: [
                        StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 100, weightUnit: .kg, reps: 5, rpe: nil),
                        StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 100, weightUnit: .kg, reps: 5, rpe: nil)
                    ]
                )
            ]
        ))
        let exercise = try XCTUnwrap(session.exercises.first)

        try await database.deleteExercise(sessionId: session.id, exerciseId: exercise.id)

        let sessionsAfter = await database.sessionsForDay(Date())
        XCTAssertFalse(sessionsAfter.flatMap(\.exercises).contains { $0.id == exercise.id })
        XCTAssertFalse(sessionsAfter.contains { $0.id == session.id }, "清空后的 session 应一并移除")
    }

    // 训练进行中删除计划动作：live session 同步剔除；动作删空则训练取消。
    func testDeletingPlanExercisePrunesLiveSession() async throws {
        let suiteName = "TodayExerciseDeleteTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LocalTrainingPlanService(database: database),
            workoutService: LocalWorkoutService(database: database),
            liveActivityManager: NoOpPlanLiveActivityManager(),
            sessionDefaults: defaults
        )

        _ = try await database.addPlannedExercises([
            PlanExerciseDraft(
                exerciseName: "Live A",
                isBodyweight: false,
                sets: [PlanExerciseDraft.SetDraft(targetWeight: 40, targetWeightUnit: .kg, targetReps: 10)]
            ),
            PlanExerciseDraft(
                exerciseName: "Live B",
                isBodyweight: false,
                sets: [PlanExerciseDraft.SetDraft(targetWeight: 50, targetWeightUnit: .kg, targetReps: 8)]
            )
        ])

        await viewModel.refresh()
        // 种子数据可能已有今日计划，这里只关心新加的两个动作。
        let exerciseA = try XCTUnwrap(viewModel.todayPlan?.exercises.first { $0.exerciseName == "Live A" })

        viewModel.startPlanLiveWorkout()
        let liveExerciseIds = try XCTUnwrap(viewModel.activeLiveWorkout?.exercises.map(\.id))

        await viewModel.deletePlanExercise(planExerciseId: exerciseA.id)
        XCTAssertFalse(viewModel.todayPlan?.exercises.contains { $0.id == exerciseA.id } ?? false)
        XCTAssertFalse(viewModel.activeLiveWorkout?.exercises.contains { $0.id == exerciseA.id } ?? false)

        for id in liveExerciseIds where id != exerciseA.id {
            await viewModel.deletePlanExercise(planExerciseId: id)
        }
        XCTAssertNil(viewModel.activeLiveWorkout, "动作全部删除后训练应被取消")
    }
}
