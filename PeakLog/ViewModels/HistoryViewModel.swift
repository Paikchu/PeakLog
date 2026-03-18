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
    @Published var isLoadingSessions: Bool = false
    @Published var isLoadingCalendar: Bool = false
    @Published var errorMessage: String?

    private let workoutService: WorkoutServiceProtocol

    init(workoutService: WorkoutServiceProtocol = MockWorkoutService()) {
        self.workoutService = workoutService
    }

    // MARK: - Load Calendar
    func loadCalendar() async {
        let cal = Calendar.current
        let year = cal.component(.year, from: displayedMonth)
        let month = cal.component(.month, from: displayedMonth)

        isLoadingCalendar = true
        errorMessage = nil
        do {
            let dates = try await workoutService.activeDaysInMonth(year: year, month: month)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            activeDates = Set(dates.map { formatter.string(from: $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingCalendar = false
    }

    // MARK: - Load Sessions for Day
    func loadSessionsForSelectedDate() async {
        isLoadingSessions = true
        errorMessage = nil
        do {
            sessions = try await workoutService.sessionsForDay(selectedDate)
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
        }
    }

    func goToNextWeek() {
        if let next = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: selectedDate) {
            selectedDate = next
            displayedMonth = next
        }
    }

    // MARK: - Select Day
    func selectDate(_ date: Date) {
        selectedDate = date
        displayedMonth = date
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return activeDates.contains(formatter.string(from: date))
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
}
