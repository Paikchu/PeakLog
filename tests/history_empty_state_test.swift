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

        let historySource = try! String(
            contentsOfFile: "PeakLog/Views/History/HistoryScreen.swift",
            encoding: .utf8
        )
        precondition(!historySource.contains("Text(selectedDateLabel)"), "Empty state must not repeat the header date")
        precondition(!historySource.contains("showsDailyRecordSheet"), "History empty state must not present a record form")
        precondition(!historySource.contains("history.empty.addRecord"), "History empty state must not contain an add-record action")
        print("history_empty_state_test passed")
    }
}
