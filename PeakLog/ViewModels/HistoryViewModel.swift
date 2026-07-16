import Foundation
import Combine

@MainActor
final class HistoryViewModel: ObservableObject {
    // MARK: - Calendar State
    @Published var displayedMonth: Date = Date()
    @Published var activeDates: Set<String> = []     // "yyyy-MM-dd" strings for fast lookup
    @Published var selectedDate: Date = Date()

    // MARK: - Sessions for selected day
    @Published var sessions: [WorkoutSession] = []
    @Published var runningRecords: [RunningWorkoutRecord] = []
    @Published var activePlan: TrainingPlan?
    @Published var selectedPlanDay: TrainingPlanDay?
    @Published var isLoadingSessions: Bool = false
    @Published var isLoadingCalendar: Bool = false
    @Published var isLoadingPlan: Bool = false
    @Published var errorMessage: String?

    @Published var exerciseLibrary: [ExerciseDefinition] = []

    private let workoutService: WorkoutServiceProtocol
    private let trainingPlanService: TrainingPlanServiceProtocol
    private let exerciseLibraryService: ExerciseLibraryServiceProtocol?
    private var sessionsLoadGeneration = 0

    /// `WorkoutDateFormatter` rebuilds a `Calendar` + `DateFormatter` on
    /// construction/use; `currentWeekDays()`/`calendarDays()` used to build
    /// a fresh one per call (and per day within a call, via `hasWorkout`),
    /// which adds up while scrolling the calendar. Cached as an instance
    /// property (not `static`/a global singleton) so it's naturally scoped
    /// to this view model's lifetime and stays easy to invalidate later —
    /// e.g. by reassigning it — once the formatter honors the user's
    /// timezone preference instead of always `TimeZone.current` (#29, still
    /// open).
    private lazy var workoutDateFormatter = WorkoutDateFormatter()

    init(
        workoutService: WorkoutServiceProtocol,
        trainingPlanService: TrainingPlanServiceProtocol,
        exerciseLibraryService: ExerciseLibraryServiceProtocol? = nil
    ) {
        self.workoutService = workoutService
        self.trainingPlanService = trainingPlanService
        self.exerciseLibraryService = exerciseLibraryService
    }

    convenience init() {
        self.init(
            workoutService: AppServices.workoutService,
            trainingPlanService: AppServices.trainingPlanService,
            exerciseLibraryService: AppServices.exerciseLibraryService
        )
    }

    func loadExerciseLibrary() async {
        guard let exerciseLibraryService else { return }
        exerciseLibrary = await exerciseLibraryService.fetchLibrary()
    }

    // MARK: - Load Calendar
    func loadCalendar() async {
        errorMessage = nil
        if let error = await loadCalendarSilently() {
            errorMessage = error.localizedDescription
        }
    }

    /// Core of `loadCalendar()`, but returns the failure instead of writing
    /// `errorMessage` directly. Used by `loadInitialScreenData()`, which
    /// runs all four loaders concurrently and needs a single, deterministic
    /// place to decide what `errorMessage` ends up as — see that method's
    /// doc comment.
    private func loadCalendarSilently() async -> Error? {
        let cal = Calendar.current
        let year = cal.component(.year, from: displayedMonth)
        let month = cal.component(.month, from: displayedMonth)

        isLoadingCalendar = true
        defer { isLoadingCalendar = false }
        do {
            let activeDays = try await workoutService.activeDaysInMonth(year: year, month: month)
            activeDates = Set(activeDays.map { workoutDateFormatter.string(from: $0) })
            return nil
        } catch {
            return error
        }
    }

    func loadPlan() async {
        if let error = await loadPlanSilently() {
            errorMessage = error.localizedDescription
        }
    }

    /// Core of `loadPlan()`, but returns the failure instead of writing
    /// `errorMessage` directly — see `loadCalendarSilently()`.
    private func loadPlanSilently() async -> Error? {
        isLoadingPlan = true
        defer { isLoadingPlan = false }
        do {
            activePlan = try await trainingPlanService.fetchActiveWeeklyPlan()
            selectedPlanDay = planDay(for: selectedDate, in: activePlan)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Load Sessions for Day
    func loadSessionsForSelectedDate() async {
        errorMessage = nil
        if let error = await loadSessionsForSelectedDateSilently() {
            errorMessage = error.localizedDescription
        }
    }

    /// Core of `loadSessionsForSelectedDate()`, but returns the failure
    /// instead of writing `errorMessage` directly — see
    /// `loadCalendarSilently()`. The stale-request guards (`requestGeneration`
    /// / selected-date checks) are unrelated to that and preserved as-is.
    private func loadSessionsForSelectedDateSilently() async -> Error? {
        sessionsLoadGeneration += 1
        let requestGeneration = sessionsLoadGeneration
        let requestedDate = selectedDate
        isLoadingSessions = true
        var resultError: Error?
        do {
            async let loadedSessions = workoutService.sessionsForDay(requestedDate)
            async let loadedRuns = workoutService.runningRecordsForDay(requestedDate)
            let (strengthSessions, runs) = try await (loadedSessions, loadedRuns)
            guard requestGeneration == sessionsLoadGeneration,
                  Calendar.current.isDate(requestedDate, inSameDayAs: selectedDate)
            else { return nil }
            sessions = WorkoutHistoryAggregator.mergeSessionsForHistory(strengthSessions)
            runningRecords = runs
        } catch {
            guard requestGeneration == sessionsLoadGeneration,
                  Calendar.current.isDate(requestedDate, inSameDayAs: selectedDate)
            else { return nil }
            runningRecords = []
            sessions = []
            resultError = error
        }
        if requestGeneration == sessionsLoadGeneration {
            isLoadingSessions = false
        }
        return resultError
    }

    /// Concurrently loads everything the History screen needs on first
    /// appear: plan, exercise library, calendar markers, and the selected
    /// day's sessions (issue #54 — these four are independent, so running
    /// them serially just added latency).
    ///
    /// Each loader only touches its own slice of published state — except
    /// `errorMessage`, which all of them also write on failure. Doing that
    /// from within four concurrent tasks would race: whichever loader
    /// happens to finish last in wall-clock time wins, not whichever the
    /// caller would expect (issue found in review of the #54 fix). Instead,
    /// the "silently" variants return their failure without touching
    /// `errorMessage`, and this function makes the single, deterministic
    /// write after all four have finished — ties resolve by fixed source
    /// order (plan, then calendar, then sessions) rather than by timing.
    func loadInitialScreenData() async {
        async let planError = loadPlanSilently()
        async let libraryLoad: () = loadExerciseLibrary()
        async let calendarError = loadCalendarSilently()
        async let sessionsError = loadSessionsForSelectedDateSilently()

        let (plan, calendar, sessions) = await (planError, calendarError, sessionsError)
        await libraryLoad

        errorMessage = [plan, calendar, sessions].compactMap { $0 }.first?.localizedDescription
    }

    // MARK: - Navigate Months
    func goToPreviousMonth() {
        if let prev = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) {
            displayedMonth = prev
        }
    }

    func goToNextMonth() {
        if let next = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) {
            displayedMonth = next
        }
    }

    // MARK: - Navigate Weeks
    func goToPreviousWeek() {
        if let prev = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: selectedDate) {
            selectedDate = prev
            displayedMonth = prev
            selectedPlanDay = planDay(for: prev, in: activePlan)
        }
    }

    func goToNextWeek() {
        if let next = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: selectedDate) {
            selectedDate = next
            displayedMonth = next
            selectedPlanDay = planDay(for: next, in: activePlan)
        }
    }

    func goToPreviousWeekAndRefresh() async {
        goToPreviousWeek()
        await loadCalendar()
        await loadSessionsForSelectedDate()
    }

    func goToNextWeekAndRefresh() async {
        goToNextWeek()
        await loadCalendar()
        await loadSessionsForSelectedDate()
    }

    // MARK: - Select Day
    func selectDate(_ date: Date) {
        selectedDate = date
        displayedMonth = date
        selectedPlanDay = planDay(for: date, in: activePlan)
    }

    func selectDateAndRefresh(_ date: Date) async {
        let calendar = Calendar.current
        let previousMonth = calendar.dateComponents([.year, .month], from: displayedMonth)
        let nextMonth = calendar.dateComponents([.year, .month], from: date)

        selectDate(date)

        if previousMonth.year != nextMonth.year || previousMonth.month != nextMonth.month {
            await loadCalendar()
        }

        await loadSessionsForSelectedDate()
    }

    // MARK: - Current Week Days
    func currentWeekDays() -> [CalendarDay] {
        var calendar = Calendar.current
        calendar.firstWeekday = 1

        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: selectedDate)

        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else {
            return []
        }
        let weekStart = weekInterval.start
        let planned = plannedDates

        return (0..<7).compactMap { i in
            guard let date = calendar.date(byAdding: .day, value: i, to: weekStart) else { return nil }
            let startOfDay = calendar.startOfDay(for: date)
            let monthOfDate = calendar.component(.month, from: date)
            let monthOfDisplay = calendar.component(.month, from: displayedMonth)
            return CalendarDay(
                id: "week-\(i)",
                date: date,
                hasWorkout: hasWorkout(on: date),
                hasPlan: startOfDay >= today && planned.contains(workoutDateFormatter.string(from: date)),
                isToday: startOfDay == today,
                isSelected: startOfDay == selectedDay,
                isCurrentMonth: monthOfDate == monthOfDisplay
            )
        }
    }

    // MARK: - Helpers
    func hasWorkout(on date: Date) -> Bool {
        activeDates.contains(workoutDateFormatter.string(from: date))
    }

    /// 激活计划里有实际动作安排的日期 key 集合，用于周条空心点。
    var plannedDates: Set<String> {
        guard let activePlan else { return [] }
        return Set(activePlan.days.filter { !$0.exercises.isEmpty }.map(\.planDate))
    }

    var isSelectedDateToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    /// 统一训练页的时态（past / today / futureInPlanWeek / futureBeyondPlan）。
    var selectedDayTense: DayTense {
        DayTense.resolve(
            selectedDate: selectedDate,
            today: Date(),
            planWeekStartDate: activePlan?.weekStartDate,
            formatter: workoutDateFormatter
        )
    }

    func selectTodayAndRefresh() async {
        await selectDateAndRefresh(Date())
    }

    var completedDaySummary: CompletedDaySummary {
        HistoryCompletedAggregator.daySummary(
            selectedDate: selectedDate,
            sessions: sessions,
            runningRecords: runningRecords
        )
    }

    var completedStrengthExercises: [CompletedStrengthExerciseViewData] {
        HistoryCompletedAggregator.strengthExercises(from: sessions)
    }

    var completedCardioRecords: [CompletedCardioRecordViewData] {
        HistoryCompletedAggregator.cardioRecords(from: runningRecords)
    }

    var hasCompletedRecords: Bool {
        completedDaySummary.hasCompletedRecords
    }

    var completedMuscleGroups: [MuscleGroup] {
        HistoryCompletedAggregator.dominantMuscleGroups(
            sessions: sessions,
            library: exerciseLibrary
        )
    }

    var displayedMonthTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: displayedMonth)
    }

    /// Builds the 6-row × 7-column grid for the displayed month.
    func calendarDays() -> [CalendarDay] {
        var calendar = Calendar.current
        calendar.firstWeekday = 1 // Sunday

        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: selectedDate)

        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)),
              let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: monthStart) - 1
        let totalDays = calendar.component(.day, from: monthEnd)
        let planned = plannedDates

        func hasPlan(on date: Date) -> Bool {
            calendar.startOfDay(for: date) >= today && planned.contains(workoutDateFormatter.string(from: date))
        }

        var days: [CalendarDay] = []

        // Leading empty days
        for i in 0..<firstWeekday {
            if let prevDate = calendar.date(byAdding: .day, value: -(firstWeekday - i), to: monthStart) {
                days.append(CalendarDay(
                    id: "prev-\(i)",
                    date: prevDate,
                    hasWorkout: hasWorkout(on: prevDate),
                    hasPlan: hasPlan(on: prevDate),
                    isToday: calendar.startOfDay(for: prevDate) == today,
                    isSelected: calendar.startOfDay(for: prevDate) == selectedDay,
                    isCurrentMonth: false
                ))
            }
        }

        // Month days
        for day in 1...totalDays {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) {
                days.append(CalendarDay(
                    id: "day-\(day)",
                    date: date,
                    hasWorkout: hasWorkout(on: date),
                    hasPlan: hasPlan(on: date),
                    isToday: calendar.startOfDay(for: date) == today,
                    isSelected: calendar.startOfDay(for: date) == selectedDay,
                    isCurrentMonth: true
                ))
            }
        }

        // Trailing days to complete 6 rows (42 cells)
        let remaining = 42 - days.count
        for i in 1...max(1, remaining) {
            if let nextDate = calendar.date(byAdding: .day, value: i, to: monthEnd) {
                days.append(CalendarDay(
                    id: "next-\(i)",
                    date: nextDate,
                    hasWorkout: hasWorkout(on: nextDate),
                    hasPlan: hasPlan(on: nextDate),
                    isToday: calendar.startOfDay(for: nextDate) == today,
                    isSelected: calendar.startOfDay(for: nextDate) == selectedDay,
                    isCurrentMonth: false
                ))
            }
        }

        return Array(days.prefix(42))
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async {
        do {
            let updatedSet = try await trainingPlanService.completePlannedSet(
                planSetId: planSetId,
                actualWeight: actualWeight,
                actualWeightUnit: actualWeightUnit,
                actualReps: actualReps
            )

            if var plan = activePlan {
                for dayIndex in plan.days.indices {
                    for exerciseIndex in plan.days[dayIndex].exercises.indices {
                        if let setIndex = plan.days[dayIndex].exercises[exerciseIndex].sets.firstIndex(where: { $0.id == planSetId }) {
                            plan.days[dayIndex].exercises[exerciseIndex].sets[setIndex] = updatedSet
                        }
                    }
                }
                activePlan = plan
                selectedPlanDay = planDay(for: selectedDate, in: plan)
            }

            await loadSessionsForSelectedDate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func planDay(for date: Date, in plan: TrainingPlan?) -> TrainingPlanDay? {
        guard let plan else { return nil }
        return plan.days.first(where: { $0.planDate == workoutDateFormatter.string(from: date) })
    }
}
