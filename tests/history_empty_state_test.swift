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

        // 过去日内容区（原 HistoryScreen 的空态承载方）保持只读事实陈述：
        // 不重复头部日期、不提供补录表单，也不展示"计划了但没练"的信息。
        let pastDaySource = try! String(
            contentsOfFile: "PeakLog/Views/Training/PastDayContent.swift",
            encoding: .utf8
        )
        precondition(!pastDaySource.contains("Text(selectedDateLabel)"), "Empty state must not repeat the header date")
        precondition(!pastDaySource.contains("showsDailyRecordSheet"), "Past day empty state must not present a record form")
        precondition(!pastDaySource.contains("history.empty.addRecord"), "Past day empty state must not contain an add-record action")
        precondition(
            !pastDaySource.contains("PlanDayPreviewSection") && !pastDaySource.contains("selectedPlanDay"),
            "Past days must not surface planned-but-unexecuted plan details"
        )
        print("history_empty_state_test passed")
    }
}
