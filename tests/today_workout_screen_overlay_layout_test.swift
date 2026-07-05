import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = rootURL.appendingPathComponent("PeakLog/Views/Today/TodayWorkoutScreen.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)
let viewModelSourceURL = rootURL.appendingPathComponent("PeakLog/ViewModels/TodayWorkoutViewModel.swift")
let viewModelSource = try String(contentsOf: viewModelSourceURL, encoding: .utf8)

precondition(
    !source.contains("ChatInputBar("),
    "Expected today screen to stop rendering the fixed chat input bar"
)
precondition(
    !source.contains("TodayAIFloatingOverlay"),
    "Expected today screen to remove the AI conversation overlay"
)
precondition(
    source.contains("DailyRecordSheet"),
    "Expected today screen to present the daily record sheet"
)
precondition(
    source.contains("today.addDailyRecord"),
    "Expected today screen to expose a floating add daily record button"
)
precondition(
    viewModelSource.contains("func addDailyRecord"),
    "Expected today view model to support direct daily records"
)

print("today_workout_screen_overlay_layout_test passed")
