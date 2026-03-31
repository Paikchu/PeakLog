import Foundation

let sourceURL = URL(fileURLWithPath: "/Users/max/Developer/IOS/PeakLog/PeakLog/Views/Today/TodayWorkoutScreen.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)
let viewModelSourceURL = URL(fileURLWithPath: "/Users/max/Developer/IOS/PeakLog/PeakLog/ViewModels/TodayWorkoutViewModel.swift")
let viewModelSource = try String(contentsOf: viewModelSourceURL, encoding: .utf8)

precondition(
    source.contains("TodayAIFloatingOverlay("),
    "Expected today screen to render the floating AI overlay"
)
precondition(
    !source.contains("assistantReplyCard"),
    "Expected today screen to stop rendering the old fixed AI result card"
)
precondition(
    !viewModelSource.contains("scheduleOverlayAutoDismissIfNeeded"),
    "Expected floating overlay to remain until the user dismisses it"
)

print("today_workout_screen_overlay_layout_test passed")
