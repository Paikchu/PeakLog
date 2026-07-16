import Foundation

/// 统一训练页的"时态"：选中日期相对今天与当前计划周的位置，
/// 决定内容区渲染成 只读记录 / 可交互计划 / 只读预览 / 周外占位。
nonisolated enum DayTense: Equatable {
    case past
    case today
    case futureInPlanWeek
    case futureBeyondPlan

    /// 纯函数解析，方便独立测试。`planWeekStartDate` 是激活计划的
    /// `weekStartDate`（"yyyy-MM-dd"），计划固定覆盖 7 天；为 nil 或
    /// 解析失败时，所有未来日期都视为周外。
    static func resolve(
        selectedDate: Date,
        today: Date,
        planWeekStartDate: String?,
        formatter: WorkoutDateFormatter
    ) -> DayTense {
        let calendar = formatter.calendar
        let selected = calendar.startOfDay(for: selectedDate)
        let todayStart = calendar.startOfDay(for: today)

        if selected < todayStart { return .past }
        if selected == todayStart { return .today }

        guard let weekStartString = planWeekStartDate,
              let weekStart = formatter.date(from: weekStartString),
              let weekEnd = calendar.date(byAdding: .day, value: 6, to: calendar.startOfDay(for: weekStart))
        else { return .futureBeyondPlan }

        return selected <= weekEnd ? .futureInPlanWeek : .futureBeyondPlan
    }
}
