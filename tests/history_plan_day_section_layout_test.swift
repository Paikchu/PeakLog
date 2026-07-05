import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = rootURL.appendingPathComponent("PeakLog/Views/History/HistoryPlanDaySection.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)

precondition(
    !source.contains("checkmark.circle.fill"),
    "Expected history plan day section to stop rendering completed-state circle icons"
)
precondition(
    !source.contains("Image(systemName: set.isCompleted ? \"checkmark.circle.fill\" : \"circle\")"),
    "Expected history plan day section to remove the trailing completion indicator"
)
precondition(
    !source.contains("Button {"),
    "Expected history plan day section sets to become non-interactive display rows"
)

print("history_plan_day_section_layout_test passed")
