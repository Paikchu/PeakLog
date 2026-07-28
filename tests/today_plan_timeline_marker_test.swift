import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("PeakLog/Views/Today/TodayWorkoutScreen.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)

precondition(
    source.contains("private struct PlanTimelineMarker"),
    "Expected the normal plan list to define the timeline marker decoration"
)
precondition(
    source.contains("firstPendingExerciseId"),
    "Expected the amber marker to follow the first unfinished exercise"
)
precondition(
    source.contains("if !state.isFocusMode"),
    "Expected timeline decorations to stay out of training focus mode"
)
precondition(
    source.contains("Color.accentPrimary") && source.contains("Color.appSeparator"),
    "Expected active and inactive markers to use semantic app theme colors"
)
precondition(
    source.contains("timelineRail") && source.contains(".frame(width: 2)"),
    "Expected exercise markers to be joined by a two-point vertical rail"
)

print("today_plan_timeline_marker_test passed")
