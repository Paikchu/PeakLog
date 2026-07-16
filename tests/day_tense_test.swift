import Foundation

// 验收命令：
// swiftc -parse-as-library PeakLog/Support/DayTense.swift PeakLog/Support/WorkoutDateFormatter.swift \
//   tests/day_tense_test.swift -o /tmp/day_tense_test && /tmp/day_tense_test
@main
struct DayTenseTestRunner {
    static func main() {
        let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let today = formatter.date(from: "2026-07-16")! // 周四；计划周 07-13（周一）起

        func resolve(_ dayKey: String, weekStart: String?) -> DayTense {
            DayTense.resolve(
                selectedDate: formatter.date(from: dayKey)!,
                today: today,
                planWeekStartDate: weekStart,
                formatter: formatter
            )
        }

        precondition(resolve("2026-07-15", weekStart: "2026-07-13") == .past, "昨天应为 past")
        precondition(resolve("2025-12-31", weekStart: "2026-07-13") == .past, "跨年过去日期应为 past")
        precondition(resolve("2026-07-16", weekStart: "2026-07-13") == .today, "今天应为 today")
        precondition(
            resolve("2026-07-17", weekStart: "2026-07-13") == .futureInPlanWeek,
            "计划周内的明天应为 futureInPlanWeek"
        )
        precondition(
            resolve("2026-07-19", weekStart: "2026-07-13") == .futureInPlanWeek,
            "计划周最后一天（weekStart+6）应为 futureInPlanWeek"
        )
        precondition(
            resolve("2026-07-20", weekStart: "2026-07-13") == .futureBeyondPlan,
            "计划周后的第一天应为 futureBeyondPlan"
        )
        precondition(
            resolve("2026-07-17", weekStart: nil) == .futureBeyondPlan,
            "无激活计划时未来日期应为 futureBeyondPlan"
        )
        precondition(
            resolve("2026-07-17", weekStart: "not-a-date") == .futureBeyondPlan,
            "weekStartDate 解析失败时未来日期应为 futureBeyondPlan"
        )
        // 计划周落后于今天（一直没生成新计划）时，未来日期一律周外。
        precondition(
            resolve("2026-07-18", weekStart: "2026-07-06") == .futureBeyondPlan,
            "过期计划周不覆盖未来日期"
        )

        print("day_tense_test passed")
    }
}
