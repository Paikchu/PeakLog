import Foundation

@main
struct HistoryEmptyStateTestRunner {
    static func main() {
        let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let today = formatter.date(from: "2026-07-10")!
        let past = formatter.date(from: "2026-07-08")!

        let todayContent = HistoryEmptyStateContent.resolve(
            selectedDate: today,
            today: today,
            locale: Locale(identifier: "zh_CN")
        )
        precondition(todayContent.isToday, "Expected today-specific empty state")

        let pastContent = HistoryEmptyStateContent.resolve(
            selectedDate: past,
            today: today,
            locale: Locale(identifier: "zh_CN")
        )
        precondition(!pastContent.isToday, "Past date must not use today state")
        print("history_empty_state_test passed")
    }
}
