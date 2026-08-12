import XCTest
@testable import PeakLog

@MainActor
final class TodayWorkoutFocusFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "TodayWorkoutFocusFlowTests"

    // `setUp()`/`tearDown()` are the `async throws` variants, not the sync ones:
    // the sync overrides are nonisolated on `XCTestCase`, so a `@MainActor` test
    // case cannot touch its own main-actor properties in them under the Swift 6
    // language mode. The async variants may carry the class's isolation
    // (issue #137).
    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeViewModel() -> TodayWorkoutViewModel {
        TodayWorkoutViewModel(
            trainingPlanService: FocusFlowTrainingPlanService(),
            workoutService: FocusFlowWorkoutService(),
            liveActivityManager: NoOpPlanLiveActivityManager(),
            sessionDefaults: defaults
        )
    }

    private func startSession(_ viewModel: TodayWorkoutViewModel) async {
        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
    }

    func testStartingSessionEntersFocusModeAtFirstExercise() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)

        XCTAssertTrue(viewModel.isTrainingFocusActive)
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-1")
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentSet?.id, "ex-1-set-1")
    }

    func testManuallyFocusedExerciseBecomesCurrentAndReturnsToEarliestWhenDone() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)

        // 滑动锁定第三个动作
        viewModel.focusLiveExercise(id: "ex-3")
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-3")
        XCTAssertEqual(viewModel.activeLiveWorkout?.manualFocusExerciseId, "ex-3")

        // 完成锁定动作的全部组后，指针回到最早未完成的 ex-1
        viewModel.completeCurrentLiveSet()
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-3")
        viewModel.completeCurrentLiveSet()
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-1")
        XCTAssertNil(viewModel.activeLiveWorkout?.manualFocusExerciseId)
    }

    /// 完成一组不得把游标（以及粘性的 `manualFocusExerciseId`）挪到别的动作上——
    /// 只要当前动作还有没做完的组，就应该原地停在它上面。
    ///
    /// 这条对应的线上问题是在 View 层：`scrollPosition(id:)` 的回写被当成"用户滑到
    /// 这里了"，而点「完成本组」引起的布局变化（底部休息面板顶掉胶囊按钮）本身就会
    /// 触发回写，于是每完成一组都可能把焦点钉到屏幕中心的那个动作上。View 层的护栏
    /// 在 `tests/plan_focus_training_mode_test.swift`，这里守住 view model 一侧：
    /// 除 `focusLiveExercise` 外没有任何路径可以设置手动锁。
    func testCompletingASetKeepsFocusOnTheSameExerciseAndSetsNoManualLock() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)

        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-1")

        // ex-1 还有第 2 组，游标留在 ex-1，且不产生手动锁。
        viewModel.completeCurrentLiveSet()
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-1")
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentSet?.id, "ex-1-set-2")
        XCTAssertNil(viewModel.activeLiveWorkout?.manualFocusExerciseId)

        // 休息倒计时开始（底部栏换成休息面板的那次布局变化）后同样不动焦点。
        XCTAssertNotNil(viewModel.restEndDate)
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-1")

        // 做完 ex-1 才按计划顺序流转到 ex-2，依旧没有手动锁。
        viewModel.completeCurrentLiveSet()
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-2")
        XCTAssertNil(viewModel.activeLiveWorkout?.manualFocusExerciseId)
    }

    func testSkippedExerciseSinksToEndOfQueue() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)

        viewModel.skipCurrentLiveExercise()
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-2")
        XCTAssertEqual(viewModel.activeLiveWorkout?.skippedExerciseIds, ["ex-1"])

        // 其余动作全部完成后，指针回落到被跳过的 ex-1
        for _ in 0..<4 {
            viewModel.completeCurrentLiveSet()
        }
        XCTAssertEqual(viewModel.activeLiveWorkout?.currentExercise?.id, "ex-1")
    }

    func testCompletingSetStartsRestCountdownButNotAfterFinalSet() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)

        viewModel.completeCurrentLiveSet()
        XCTAssertNotNil(viewModel.restEndDate)

        viewModel.skipRest()
        XCTAssertNil(viewModel.restEndDate)

        for _ in 0..<5 {
            viewModel.completeCurrentLiveSet()
        }
        XCTAssertEqual(viewModel.activeLiveWorkout?.isComplete, true)
        XCTAssertNil(viewModel.restEndDate)
    }

    func testAlreadyPersistedSetsCannotBeUnchecked() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)

        // ex-2-set-1 在 fixture 中已落库
        XCTAssertEqual(viewModel.activeLiveWorkout?.completedSetIds.contains("ex-2-set-1"), true)
        viewModel.toggleLiveSet(setId: "ex-2-set-1")
        XCTAssertEqual(viewModel.activeLiveWorkout?.completedSetIds.contains("ex-2-set-1"), true)

        // session 内完成的组可以撤销
        viewModel.toggleLiveSet(setId: "ex-1-set-1")
        XCTAssertEqual(viewModel.activeLiveWorkout?.completedSetIds.contains("ex-1-set-1"), true)
        viewModel.toggleLiveSet(setId: "ex-1-set-1")
        XCTAssertEqual(viewModel.activeLiveWorkout?.completedSetIds.contains("ex-1-set-1"), false)
    }

    func testSessionPersistsAndRestoresMinimizedOnSameDay() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)
        viewModel.completeCurrentLiveSet()
        let sessionId = viewModel.activeLiveWorkout?.id

        // completeCurrentLiveSet 之后的落盘现在是去抖的（见 #18），等去抖窗口过去
        // 再模拟 App 被杀后重新启动，确保读到的是去抖写盘之后的最新状态。
        try? await Task.sleep(for: .milliseconds(600))

        let restored = makeViewModel()
        await restored.refresh()

        XCTAssertEqual(restored.activeLiveWorkout?.id, sessionId)
        XCTAssertEqual(restored.activeLiveWorkout?.completedSetIds.contains("ex-1-set-1"), true)
        XCTAssertFalse(restored.isTrainingFocusActive)
    }

    // #18 follow-up: the debounced write must be forceable to land immediately
    // (e.g. when the app is about to be backgrounded/killed) rather than only
    // eventually landing after the debounce window elapses.
    func testFlushPendingLiveWorkoutPersistenceLandsDebouncedWriteImmediately() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)
        viewModel.completeCurrentLiveSet()
        let sessionId = viewModel.activeLiveWorkout?.id

        // No sleep here — this proves the flush itself forces the pending
        // debounced write to disk synchronously, without waiting out the
        // debounce window like testSessionPersistsAndRestoresMinimizedOnSameDay
        // does. This is what ContentView calls when scenePhase goes
        // .inactive/.background, so a set completion isn't lost if the app is
        // killed inside the debounce window.
        viewModel.flushPendingLiveWorkoutPersistence()

        let restored = makeViewModel()
        await restored.refresh()

        XCTAssertEqual(restored.activeLiveWorkout?.id, sessionId)
        XCTAssertEqual(restored.activeLiveWorkout?.completedSetIds.contains("ex-1-set-1"), true)
    }

    func testCancelClearsPersistedSessionAndFocusState() async {
        let viewModel = makeViewModel()
        await startSession(viewModel)
        viewModel.cancelPlanLiveWorkout()

        XCTAssertNil(viewModel.activeLiveWorkout)
        XCTAssertFalse(viewModel.isTrainingFocusActive)

        let restored = makeViewModel()
        await restored.refresh()
        XCTAssertNil(restored.activeLiveWorkout)
    }
}

// MARK: - Fixtures

private final class FocusFlowTrainingPlanService: TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        func makeSet(_ exercise: String, _ index: Int, completed: Bool = false) -> TrainingPlanSet {
            TrainingPlanSet(
                id: "\(exercise)-set-\(index)",
                setIndex: index,
                targetWeight: 60,
                targetWeightUnit: .kg,
                targetReps: 8,
                completedAt: completed ? Date() : nil,
                linkedExerciseSetId: completed ? "linked-\(exercise)-set-\(index)" : nil
            )
        }

        func makeExercise(_ id: String, order: Int, sets: [TrainingPlanSet]) -> TrainingPlanExercise {
            TrainingPlanExercise(
                id: id,
                orderIndex: order,
                exerciseName: "Exercise \(order)",
                exerciseLoadType: .weighted,
                progressionMode: "weight_first",
                notes: nil,
                previousPerformanceSummary: nil,
                aiSuggestion: nil,
                sets: sets
            )
        }

        return TrainingPlanDay(
            id: "plan-day-1",
            planDate: TodayWorkoutViewModel.currentPlanDateString(),
            dayIndex: 1,
            title: "Push Strength",
            focus: "Chest",
            status: "planned",
            exercises: [
                makeExercise("ex-1", order: 1, sets: [makeSet("ex-1", 1), makeSet("ex-1", 2)]),
                makeExercise("ex-2", order: 2, sets: [makeSet("ex-2", 1, completed: true), makeSet("ex-2", 2), makeSet("ex-2", 3)]),
                makeExercise("ex-3", order: 3, sets: [makeSet("ex-3", 1), makeSet("ex-3", 2)])
            ]
        )
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: planSetId,
            setIndex: 1,
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
            setIndex: 4,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}

    func deletePlannedExercise(planExerciseId: String) async throws {}

    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay {
        (try await fetchTodayPlan())!
    }

    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay {
        (try await fetchTodayPlan())!
    }
}

private final class FocusFlowWorkoutService: WorkoutServiceProtocol {
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
    func deleteExercise(sessionId: String, exerciseId: String) async throws {}
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: 60, weightUnit: .kg, reps: 8, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] { [] }
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }

    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession {
        WorkoutSession(
            id: "session-1",
            userId: "user-1",
            date: draft.workoutDate,
            durationMinutes: nil,
            label: nil,
            exercises: [],
            createdAt: draft.workoutDate,
            updatedAt: draft.workoutDate
        )
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
