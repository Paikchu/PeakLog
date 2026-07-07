import XCTest
@testable import PeakLog

@MainActor
final class TodayWorkoutLiveSessionTests: XCTestCase {
    func testConfirmingLivePlanSessionPersistsCompletedSetsIntoTodayRecord() async {
        let trainingPlanService = LiveSessionTrainingPlanService()
        let workoutService = LiveSessionWorkoutService()
        let liveActivityManager = LiveSessionActivityManager()
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: trainingPlanService,
            workoutService: workoutService,
            liveActivityManager: liveActivityManager
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        viewModel.completeCurrentLiveSet()
        viewModel.completeCurrentLiveSet()
        await viewModel.confirmPlanLiveWorkout()

        XCTAssertNil(viewModel.activeLiveWorkout)
        XCTAssertEqual(trainingPlanService.completedPlanSetIds, ["plan-set-1", "plan-set-2"])
        XCTAssertEqual(viewModel.todayRecord?.exercises.first?.sets.count, 2)
        XCTAssertEqual(liveActivityManager.startedSessionIds.count, 1)
        XCTAssertEqual(liveActivityManager.didEndCount, 1)
    }

    func testLiveActivityCompletionSyncsBeforeConfirmingSession() async {
        let trainingPlanService = LiveSessionTrainingPlanService()
        let workoutService = LiveSessionWorkoutService()
        let liveActivityManager = LiveSessionActivityManager()
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: trainingPlanService,
            workoutService: workoutService,
            liveActivityManager: liveActivityManager
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        liveActivityManager.externallyCompletedSetIds = ["plan-set-1"]
        viewModel.syncLiveActivityCompletions()
        await viewModel.confirmPlanLiveWorkout()

        XCTAssertEqual(trainingPlanService.completedPlanSetIds, ["plan-set-1"])
        XCTAssertEqual(viewModel.todayRecord?.exercises.first?.sets.count, 1)
    }
}

private final class LiveSessionActivityManager: PlanLiveActivityManaging {
    private(set) var startedSessionIds: [String] = []
    private(set) var updatedSessionIds: [String] = []
    private(set) var didEndCount = 0
    var externallyCompletedSetIds: Set<String> = []

    func start(session: PlanLiveWorkoutSession) async {
        startedSessionIds.append(session.id)
    }

    func update(session: PlanLiveWorkoutSession) async {
        updatedSessionIds.append(session.id)
    }

    func end() async {
        didEndCount += 1
    }

    func consumeCompletedSetIds(sessionId: String) -> Set<String> {
        let ids = externallyCompletedSetIds
        externallyCompletedSetIds = []
        return ids
    }

    func completedSetIdUpdates(sessionId: String) -> AsyncStream<Set<String>> {
        AsyncStream { $0.finish() }
    }
}

private final class LiveSessionTrainingPlanService: TrainingPlanServiceProtocol {
    private(set) var completedPlanSetIds: [String] = []

    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        TrainingPlanDay(
            id: "plan-day-1",
            planDate: "2026-07-05",
            dayIndex: 1,
            title: "Push Strength",
            focus: "Chest",
            status: "planned",
            exercises: [
                TrainingPlanExercise(
                    id: "plan-exercise-1",
                    orderIndex: 0,
                    exerciseName: "Bench Press",
                    exerciseLoadType: .weighted,
                    progressionMode: "weight_first",
                    notes: nil,
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(
                            id: "plan-set-1",
                            setIndex: 1,
                            targetWeight: 60,
                            targetWeightUnit: .kg,
                            targetReps: 8,
                            completedAt: nil,
                            linkedExerciseSetId: nil
                        ),
                        TrainingPlanSet(
                            id: "plan-set-2",
                            setIndex: 2,
                            targetWeight: 60,
                            targetWeightUnit: .kg,
                            targetReps: 8,
                            completedAt: nil,
                            linkedExerciseSetId: nil
                        )
                    ]
                )
            ]
        )
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet {
        completedPlanSetIds.append(planSetId)
        return TrainingPlanSet(
            id: planSetId,
            setIndex: completedPlanSetIds.count,
            targetWeight: actualWeight,
            targetWeightUnit: actualWeightUnit,
            targetReps: actualReps,
            completedAt: Date(),
            linkedExerciseSetId: "linked-\(planSetId)"
        )
    }

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: planSetId,
            setIndex: 1,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: "\(planExerciseId)-new-set",
            setIndex: 3,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}

    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay {
        (try await fetchTodayPlan())!
    }

    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay {
        (try await fetchTodayPlan())!
    }
}

private final class LiveSessionWorkoutService: WorkoutServiceProtocol {
    private var persistedSetCount = 0
    func updateSet(
        sessionId: String,
        exerciseId: String,
        setId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: UUID().uuidString, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: 60, weightUnit: .kg, reps: 8, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        [
            WorkoutSession(
                id: "session-1",
                userId: "user-1",
                date: date,
                durationMinutes: nil,
                label: "Push Strength",
                exercises: [
                    Exercise(
                        id: "exercise-1",
                        name: "Bench Press",
                        sets: (0..<persistedSetCount).map {
                            ExerciseSet(id: "set-\($0 + 1)", setIndex: $0 + 1, weight: 60, weightUnit: .kg, reps: 8)
                        }
                    )
                ],
                createdAt: date,
                updatedAt: date
            )
        ].filter { !$0.exercises.first!.sets.isEmpty }
    }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }

    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession {
        persistedSetCount = draft.exercises.reduce(0) { $0 + $1.sets.count }
        return try await sessionsForDay(draft.workoutDate).first!
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord {
        RunningWorkoutRecord(
            id: "run-1",
            userId: "user-1",
            workoutDate: workoutDate,
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            source: source,
            createdAt: workoutDate,
            updatedAt: workoutDate
        )
    }
}
