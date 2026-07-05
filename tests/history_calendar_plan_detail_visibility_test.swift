import Foundation

let sourceURL = URL(fileURLWithPath: "/Users/max/Developer/IOS/PeakLog/PeakLog/Views/History/CalendarGridView.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)

precondition(
    !source.contains("selectedPlanSection"),
    "Expected history calendar to stop rendering the selected plan detail section"
)
precondition(
    !source.contains("HistoryPlanDaySection("),
    "Expected history calendar to stop rendering the plan day detail card"
)
precondition(
    !source.contains("No workout planned"),
    "Expected history calendar to remove the empty-state plan detail block"
)

print("history_calendar_plan_detail_visibility_test passed")
