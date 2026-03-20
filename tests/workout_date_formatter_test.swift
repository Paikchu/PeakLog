import Foundation

@main
struct WorkoutDateFormatterTestRunner {
    static func main() {
        preservesLocalCalendarDayInAsiaShanghai()
        preservesLocalCalendarDayInLosAngeles()
        print("workout_date_formatter_test passed")
    }

    private static func preservesLocalCalendarDayInAsiaShanghai() {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = WorkoutDateFormatter(timeZone: timeZone)
        let calendar = formatter.calendar
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 20))!

        precondition(
            formatter.string(from: date) == "2026-03-20",
            "Expected Shanghai local day to stay 2026-03-20"
        )
        precondition(
            calendar.component(.day, from: formatter.date(from: "2026-03-20")!) == 20,
            "Expected parsed Shanghai date to stay on the 20th"
        )
    }

    private static func preservesLocalCalendarDayInLosAngeles() {
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let formatter = WorkoutDateFormatter(timeZone: timeZone)
        let calendar = formatter.calendar
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 20))!

        precondition(
            formatter.string(from: date) == "2026-03-20",
            "Expected Los Angeles local day to stay 2026-03-20"
        )
        precondition(
            calendar.component(.day, from: formatter.date(from: "2026-03-20")!) == 20,
            "Expected parsed Los Angeles date to stay on the 20th"
        )
    }
}
