import XCTest
@testable import PeakLog

/// 回归：练完当天，月网格/周条上那天没有实心点——`activeDates` 只在初次
/// 加载和翻周/翻月时刷新，写入侧没有任何东西通知它，于是刚练完的那天要
/// 等用户翻走再翻回来才亮点。
///
/// 这里把 `TrainingScreen` 的接线原样复现（todayViewModel 写完记录 →
/// historyViewModel 重拉圆点），断言"不导航"也能同步。
@MainActor
final class CalendarActiveDayRefreshTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "CalendarActiveDayRefreshTests"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testConfirmingTodaysWorkoutLightsUpTodaysDotWithoutNavigating() async {
        let store = ActiveDayStore()
        let (today, history) = makeWiredPair(store: store)

        await history.loadCalendar()
        XCTAssertFalse(history.hasWorkout(on: Date()), "前置条件：今天还没有任何记录")

        await today.refresh()
        today.startPlanLiveWorkout()
        today.completeCurrentLiveSet()
        await today.confirmPlanLiveWorkout()

        XCTAssertTrue(
            history.hasWorkout(on: Date()),
            "确认训练后日历应立刻出现实心点，而不是等翻月再翻回来"
        )
    }

    func testCompletingASinglePlannedSetLightsUpTodaysDot() async {
        let store = ActiveDayStore()
        let (today, history) = makeWiredPair(store: store)

        await history.loadCalendar()
        await today.refresh()
        await today.completePlannedSet(planSetId: "ex-1-set-1")

        XCTAssertTrue(history.hasWorkout(on: Date()), "逐组勾选同样要让当天亮点")
    }

    func testLoggingARunLightsUpTodaysDot() async {
        let store = ActiveDayStore()
        let (today, history) = makeWiredPair(store: store)

        await history.loadCalendar()
        _ = try? await today.addRunningRecord(durationMinutes: 30, distanceKm: 5)

        XCTAssertTrue(history.hasWorkout(on: Date()), "只跑步的一天也是训练日")
    }

    /// 反向同样要成立：把当天的记录删空，圆点得跟着消失。
    func testDeletingTodaysOnlyRecordClearsTodaysDot() async {
        let store = ActiveDayStore()
        store.insert(Date())
        let (today, history) = makeWiredPair(store: store)

        await history.loadCalendar()
        await today.refresh()
        XCTAssertTrue(history.hasWorkout(on: Date()), "前置条件：今天已有记录")

        await today.deleteLoggedExercise(exerciseId: "logged-ex-1")

        XCTAssertFalse(history.hasWorkout(on: Date()), "删空当天记录后实心点应消失")
    }

    /// `refreshCalendarMarkers()` 是保存流程的收尾副作用，不该动
    /// `errorMessage`——既不清掉页面上正在显示的错误，也不用自己的失败
    /// 去盖它。
    func testRefreshCalendarMarkersLeavesErrorMessageAlone() async {
        let store = ActiveDayStore()
        let (_, history) = makeWiredPair(store: store)
        history.errorMessage = "保存失败"

        store.insert(Date())
        await history.refreshCalendarMarkers()

        XCTAssertTrue(history.hasWorkout(on: Date()))
        XCTAssertEqual(history.errorMessage, "保存失败")
    }

    // MARK: - Helpers

    /// 与 `TrainingScreen.task` 里的接线一致。
    private func makeWiredPair(store: ActiveDayStore) -> (TodayWorkoutViewModel, HistoryViewModel) {
        let workoutService = ActiveDayTrackingWorkoutService(store: store)
        let planService = ActiveDayTrackingPlanService(store: store)

        let today = TodayWorkoutViewModel(
            trainingPlanService: planService,
            workoutService: workoutService,
            liveActivityManager: NoOpPlanLiveActivityManager(),
            sessionDefaults: defaults
        )
        let history = HistoryViewModel(
            workoutService: workoutService,
            trainingPlanService: planService
        )
        today.onWorkoutDataChanged = { [weak history] in
            await history?.refreshCalendarMarkers()
        }
        return (today, history)
    }
}

// MARK: - Fixtures

/// 计划服务与训练服务共享的"哪些天有记录"存储，让写入在同一次测试里
/// 真的能被 `activeDaysInMonth` 读到。
private final class ActiveDayStore: @unchecked Sendable {
    private let lock = NSLock()
    private var days: Set<Date> = []

    func insert(_ date: Date) {
        lock.withLock { _ = days.insert(Calendar.current.startOfDay(for: date)) }
    }

    func remove(_ date: Date) {
        lock.withLock { _ = days.remove(Calendar.current.startOfDay(for: date)) }
    }

    func contains(_ date: Date) -> Bool {
        lock.withLock { days.contains(Calendar.current.startOfDay(for: date)) }
    }

    func days(inYear year: Int, month: Int) -> [Date] {
        lock.withLock {
            days.filter {
                let parts = Calendar.current.dateComponents([.year, .month], from: $0)
                return parts.year == year && parts.month == month
            }
        }
    }
}

private final class ActiveDayTrackingWorkoutService: WorkoutServiceProtocol {
    private let store: ActiveDayStore

    init(store: ActiveDayStore) {
        self.store = store
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        store.days(inYear: year, month: month)
    }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        guard store.contains(date) else { return [] }
        return [
            WorkoutSession(
                id: "session-1",
                userId: "user-1",
                date: date,
                durationMinutes: nil,
                label: nil,
                exercises: [
                    Exercise(
                        id: "logged-ex-1",
                        name: "Exercise 1",
                        sets: [ExerciseSet(id: "logged-set-1", setIndex: 1, weight: 60, weightUnit: .kg, reps: 8)]
                    )
                ],
                createdAt: date,
                updatedAt: date
            )
        ]
    }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }

    func deleteExercise(sessionId: String, exerciseId: String) async throws {
        store.remove(Date())
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {
        store.remove(Date())
    }

    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession {
        store.insert(draft.workoutDate)
        return WorkoutSession(
            id: "created-session",
            userId: "user-1",
            date: draft.workoutDate,
            durationMinutes: nil,
            label: draft.title,
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
        store.insert(workoutDate)
        return RunningWorkoutRecord(
            id: "created-run",
            userId: "user-1",
            workoutDate: workoutDate,
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            source: source,
            createdAt: workoutDate,
            updatedAt: workoutDate
        )
    }

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

    func addSet(
        sessionId: String,
        exerciseId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet {
        ExerciseSet(id: "new-set", setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: 60, weightUnit: .kg, reps: 8, rpe: rpe)
    }
}

/// 完成计划组 = 落一条记录（真实实现里会写出 linked exercise set），
/// 所以这里也往共享库里塞当天。
private final class ActiveDayTrackingPlanService: TrainingPlanServiceProtocol {
    private let store: ActiveDayStore

    init(store: ActiveDayStore) {
        self.store = store
    }

    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        TrainingPlanDay(
            id: "plan-day-1",
            planDate: TodayWorkoutViewModel.currentPlanDateString(),
            dayIndex: 1,
            title: "Push Strength",
            focus: "Chest",
            status: "planned",
            exercises: [
                TrainingPlanExercise(
                    id: "ex-1",
                    orderIndex: 1,
                    exerciseName: "Exercise 1",
                    exerciseLoadType: .weighted,
                    progressionMode: "weight_first",
                    notes: nil,
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(
                            id: "ex-1-set-1",
                            setIndex: 1,
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
        store.insert(Date())
        return TrainingPlanSet(
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
            setIndex: 2,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}

    func deletePlannedExercise(planExerciseId: String) async throws {
        store.remove(Date())
    }

    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay {
        (try await fetchTodayPlan())!
    }

    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay {
        (try await fetchTodayPlan())!
    }
}
