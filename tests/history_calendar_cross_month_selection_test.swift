import Foundation

protocol WorkoutServiceProtocol {
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession]
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord]
    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession
    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord
}

protocol TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan?
    func fetchTodayPlan() async throws -> TrainingPlanDay?
    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet
    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet
    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet
    func deletePlannedSet(planSetId: String) async throws
}

@main
struct HistoryCalendarCrossMonthSelectionTestRunner {
    static func main() async {
        validatesCrossMonthCalendarDayInteractionRules()
        await selectsCrossMonthDateAndUpdatesDisplayedMonth()
        await loadCalendarUsesMergedActiveDaysOnce()
        await weekNavigationRefreshesSelectedDayRecords()
        print("history_calendar_cross_month_selection_test passed")
    }

    private static func validatesCrossMonthCalendarDayInteractionRules() {
        let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let crossMonthSelectedDay = CalendarDay(
            id: "selected-cross-month",
            date: formatter.date(from: "2026-04-01")!,
            hasWorkout: true,
            isToday: false,
            isSelected: true,
            isCurrentMonth: false
        )

        precondition(crossMonthSelectedDay.isInteractable, "Expected cross-month day in the visible week to stay tappable")
        precondition(crossMonthSelectedDay.showsSelectionHighlight, "Expected selected cross-month day to render the selected highlight")
        precondition(crossMonthSelectedDay.showsWorkoutIndicator, "Expected workout dot to remain visible for selected cross-month day")
        precondition(crossMonthSelectedDay.textColorRole == .selected, "Expected selected cross-month day to use selected text styling")

        let crossMonthToday = CalendarDay(
            id: "today-cross-month",
            date: formatter.date(from: "2026-04-02")!,
            hasWorkout: false,
            isToday: true,
            isSelected: false,
            isCurrentMonth: false
        )

        precondition(crossMonthToday.showsTodayOutline, "Expected cross-month today cell to render today outline when not selected")
        precondition(crossMonthToday.textColorRole == .muted, "Expected unselected cross-month day to remain visually muted")
    }

    @MainActor
    private static func selectsCrossMonthDateAndUpdatesDisplayedMonth() async {
        let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let workoutService = HistoryCalendarSelectionWorkoutService()
        let trainingPlanService = HistoryCalendarSelectionTrainingPlanService()
        let viewModel = HistoryViewModel(
            workoutService: workoutService,
            trainingPlanService: trainingPlanService
        )

        viewModel.displayedMonth = formatter.date(from: "2026-03-30")!
        await viewModel.loadPlan()

        let crossMonthDate = formatter.date(from: "2026-04-01")!
        viewModel.selectDate(crossMonthDate)

        precondition(
            formatter.string(from: viewModel.selectedDate) == "2026-04-01",
            "Expected selected date to switch to the cross-month day"
        )
        precondition(
            formatter.string(from: viewModel.displayedMonth) == "2026-04-01",
            "Expected displayed month anchor to follow the selected cross-month day"
        )
        precondition(
            viewModel.selectedPlanDay?.planDate == "2026-04-01",
            "Expected selected plan day to refresh for the cross-month date"
        )
    }

    @MainActor
    private static func loadCalendarUsesMergedActiveDaysOnce() async {
        let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let workoutService = CountingMergedActiveDaysWorkoutService(
            activeDays: [formatter.date(from: "2026-08-04")!]
        )
        let viewModel = HistoryViewModel(
            workoutService: workoutService,
            trainingPlanService: HistoryCalendarSelectionTrainingPlanService()
        )

        viewModel.displayedMonth = formatter.date(from: "2026-08-01")!
        await viewModel.loadCalendar()

        precondition(
            workoutService.calendarRequestCount == 1,
            "Expected loadCalendar to use the merged active day query once"
        )
        precondition(
            viewModel.activeDates == ["2026-08-04"],
            "Expected merged active day results to populate calendar markers"
        )
    }

    @MainActor
    private static func weekNavigationRefreshesSelectedDayRecords() async {
        let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let today = formatter.date(from: "2026-08-09")!
        let previousWeek = formatter.date(from: "2026-08-02")!
        let todaySession = makeSession(id: "today-session", date: today, exerciseName: "杠铃卧推")
        let previousWeekSession = makeSession(id: "previous-week-session", date: previousWeek, exerciseName: "深蹲")

        let viewModel = HistoryViewModel(
            workoutService: HistoryCalendarSelectionWorkoutService(
                sessionsByDay: [
                    "2026-08-09": [todaySession],
                    "2026-08-02": [previousWeekSession]
                ]
            ),
            trainingPlanService: HistoryCalendarSelectionTrainingPlanService()
        )

        viewModel.selectDate(today)
        await viewModel.loadSessionsForSelectedDate()
        precondition(
            viewModel.sessions.first?.exercises.first?.name == "杠铃卧推",
            "Expected initial selected day records to load"
        )

        await viewModel.goToPreviousWeekAndRefresh()

        precondition(
            formatter.string(from: viewModel.selectedDate) == "2026-08-02",
            "Expected previous week navigation to move selected date"
        )
        precondition(
            viewModel.sessions.first?.exercises.first?.name == "深蹲",
            "Expected week navigation to refresh records for the new selected day"
        )
    }

    private static func makeSession(id: String, date: Date, exerciseName: String) -> WorkoutSession {
        WorkoutSession(
            id: id,
            userId: "user-1",
            date: date,
            durationMinutes: 30,
            label: nil,
            exercises: [
                Exercise(
                    id: "\(id)-exercise",
                    name: exerciseName,
                    sets: [
                        ExerciseSet(id: "\(id)-set", setIndex: 1, weight: 50, weightUnit: .kg, reps: 8)
                    ]
                )
            ],
            createdAt: date,
            updatedAt: date
        )
    }
}

private final class CountingMergedActiveDaysWorkoutService: WorkoutServiceProtocol {
    private let lock = NSLock()
    private let activeDays: [Date]
    private var requestCount = 0

    var calendarRequestCount: Int {
        lock.withLock { requestCount }
    }

    init(activeDays: [Date]) {
        self.activeDays = activeDays
    }

    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise {
        Exercise(id: exerciseId, name: name, sets: [])
    }

    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: "new-set", setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}

    func deleteExercise(sessionId: String, exerciseId: String) async throws {}

    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: nil, weightUnit: .kg, reps: 0, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        lock.withLock { requestCount += 1 }
        return activeDays
    }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] { [] }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }

    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession {
        WorkoutSession(
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
        RunningWorkoutRecord(
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
}

enum AppServices {
    static let workoutService: WorkoutServiceProtocol = HistoryCalendarSelectionWorkoutService()
    static let trainingPlanService: TrainingPlanServiceProtocol = HistoryCalendarSelectionTrainingPlanService()
}

private struct HistoryCalendarSelectionWorkoutService: WorkoutServiceProtocol {
    var sessionsByDay: [String: [WorkoutSession]] = [:]
    private let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: "new-set", setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: nil, weightUnit: .kg, reps: 0, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        sessionsByDay.keys.compactMap(formatter.date(from:))
    }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        sessionsByDay[formatter.string(from: date)] ?? []
    }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] {
        []
    }

    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession {
        WorkoutSession(
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
        RunningWorkoutRecord(
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
}

actor SupabaseWorkoutService: WorkoutServiceProtocol {
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: "stub-set", setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: nil, weightUnit: .kg, reps: 0, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] { [] }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }

    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession {
        WorkoutSession(
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
        RunningWorkoutRecord(
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
}

private struct HistoryCalendarSelectionTrainingPlanService: TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? {
        TrainingPlan(
            id: "plan-cross-month",
            weekStartDate: "2026-03-30",
            goalSummary: nil,
            coachSummary: "Cross-month week",
            days: [
                TrainingPlanDay(
                    id: "day-1",
                    planDate: "2026-03-31",
                    dayIndex: 1,
                    title: "Recovery",
                    focus: nil,
                    status: "planned",
                    exercises: []
                ),
                TrainingPlanDay(
                    id: "day-2",
                    planDate: "2026-04-01",
                    dayIndex: 2,
                    title: "Pull",
                    focus: "Back",
                    status: "planned",
                    exercises: []
                )
            ]
        )
    }

    func fetchTodayPlan() async throws -> TrainingPlanDay? { nil }

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
            completedAt: nil,
            linkedExerciseSetId: nil
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
            id: planExerciseId,
            setIndex: 1,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}
}

struct SupabaseTrainingPlanService: TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }
    func fetchTodayPlan() async throws -> TrainingPlanDay? { nil }

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
            completedAt: nil,
            linkedExerciseSetId: nil
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
            id: planExerciseId,
            setIndex: 1,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}
}
