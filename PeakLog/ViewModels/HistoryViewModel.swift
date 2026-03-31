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
    @Published var activePlan: TrainingPlan?
    @Published var selectedPlanDay: TrainingPlanDay?
    @Published var isLoadingSessions: Bool = false
    @Published var isLoadingCalendar: Bool = false
    @Published var isLoadingPlan: Bool = false
    @Published var errorMessage: String?

    private let workoutService: WorkoutServiceProtocol
    private let trainingPlanService: TrainingPlanServiceProtocol

    init(
        workoutService: WorkoutServiceProtocol = SupabaseWorkoutService(),
        trainingPlanService: TrainingPlanServiceProtocol = SupabaseTrainingPlanService()
    ) {
        self.workoutService = workoutService
        self.trainingPlanService = trainingPlanService
    }

    // MARK: - Load Calendar
    func loadCalendar() async {
        let cal = Calendar.current
        let year = cal.component(.year, from: displayedMonth)
        let month = cal.component(.month, from: displayedMonth)
        let workoutDateFormatter = WorkoutDateFormatter()

        isLoadingCalendar = true
        errorMessage = nil
        do {
            let dates = try await workoutService.activeDaysInMonth(year: year, month: month)
            activeDates = Set(dates.map { workoutDateFormatter.string(from: $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingCalendar = false
    }

    func loadPlan() async {
        isLoadingPlan = true
        do {
            activePlan = try await trainingPlanService.fetchActiveWeeklyPlan()
            selectedPlanDay = planDay(for: selectedDate, in: activePlan)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingPlan = false
    }

    // MARK: - Load Sessions for Day
    func loadSessionsForSelectedDate() async {
        isLoadingSessions = true
        errorMessage = nil
        do {
            let loadedSessions = try await workoutService.sessionsForDay(selectedDate)
            sessions = WorkoutHistoryAggregator.mergeSessionsForHistory(loadedSessions)
        } catch {
            errorMessage = error.localizedDescription
            sessions = []
        }
        isLoadingSessions = false
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

        return (0..<7).compactMap { i in
            guard let date = calendar.date(byAdding: .day, value: i, to: weekStart) else { return nil }
            let startOfDay = calendar.startOfDay(for: date)
            let monthOfDate = calendar.component(.month, from: date)
            let monthOfDisplay = calendar.component(.month, from: displayedMonth)
            return CalendarDay(
                id: "week-\(i)",
                date: date,
                hasWorkout: hasWorkout(on: date),
                isToday: startOfDay == today,
                isSelected: startOfDay == selectedDay,
                isCurrentMonth: monthOfDate == monthOfDisplay
            )
        }
    }

    // MARK: - Helpers
    func hasWorkout(on date: Date) -> Bool {
        let workoutDateFormatter = WorkoutDateFormatter()
        return activeDates.contains(workoutDateFormatter.string(from: date))
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

        var days: [CalendarDay] = []

        // Leading empty days
        for i in 0..<firstWeekday {
            if let prevDate = calendar.date(byAdding: .day, value: -(firstWeekday - i), to: monthStart) {
                days.append(CalendarDay(
                    id: "prev-\(i)",
                    date: prevDate,
                    hasWorkout: hasWorkout(on: prevDate),
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
        let formatter = WorkoutDateFormatter()
        return plan.days.first(where: { $0.planDate == formatter.string(from: date) })
    }
}
