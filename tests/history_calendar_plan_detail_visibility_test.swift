import Foundation

// 周历条（原 CalendarGridView）只负责日期导航与状态圆点，
// 计划/记录明细由时态内容区渲染，不得回流进日历组件。
let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = rootURL.appendingPathComponent("PeakLog/Views/Training/WeekCalendarStrip.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)

precondition(
    !source.contains("selectedPlanSection"),
    "Expected the week strip to stop rendering the selected plan detail section"
)
precondition(
    !source.contains("HistoryPlanDaySection(") && !source.contains("PlanDayPreviewSection("),
    "Expected the week strip to stop rendering the plan day detail card"
)
precondition(
    !source.contains("No workout planned"),
    "Expected the week strip to keep no empty-state plan detail block"
)
precondition(
    source.contains("showsPlanIndicator") && source.contains("showsWorkoutIndicator"),
    "Expected day cells to render both the solid record dot and the hollow plan dot"
)

print("history_calendar_plan_detail_visibility_test passed")
