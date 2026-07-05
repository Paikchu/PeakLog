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
    "Expected floating plus to present the manual daily record sheet"
)
precondition(
    !source.contains("PlanComposerSheet"),
    "Expected floating plus to stop presenting the free-form plan composer"
)
precondition(
    source.contains("today.addDailyRecord") && source.contains("today.addPlanExercise"),
    "Expected floating plus to expose both manual daily record and manual plan exercise semantics"
)
precondition(
    source.contains("\"开始训练\"") && source.contains("today.startPlan"),
    "Expected existing plans to keep the Start Plan action"
)
precondition(
    source.contains("TrainingSessionScreen"),
    "Expected Start Plan to present the full-plan training session screen"
)
precondition(
    viewModelSource.contains("liveActivityManager.start") && viewModelSource.contains("liveActivityManager.update"),
    "Expected starting a plan to bridge the app session into ActivityKit"
)
precondition(
    viewModelSource.contains("func toggleLiveSet") && viewModelSource.contains("func addPlanExercise"),
    "Expected the view model to support toggling any set and manually adding plan exercises"
)

print("today_workout_screen_overlay_layout_test passed")
