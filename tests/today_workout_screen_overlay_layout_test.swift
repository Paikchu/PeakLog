import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = rootURL.appendingPathComponent("PeakLog/Views/Today/TodayWorkoutScreen.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)
let viewModelSourceURL = rootURL.appendingPathComponent("PeakLog/ViewModels/TodayWorkoutViewModel.swift")
let viewModelSource = try String(contentsOf: viewModelSourceURL, encoding: .utf8)
let dockSourceURL = rootURL.appendingPathComponent("PeakLog/Views/Home/HomeDockBar.swift")
let dockSource = try String(contentsOf: dockSourceURL, encoding: .utf8)
let contentViewSourceURL = rootURL.appendingPathComponent("PeakLog/ContentView.swift")
let contentViewSource = try String(contentsOf: contentViewSourceURL, encoding: .utf8)

precondition(
    !source.contains("ChatInputBar("),
    "Expected today screen to stop rendering the fixed chat input bar"
)
precondition(
    !source.contains("TextEditor("),
    "Expected today screen to have no free-form natural-language editor"
)
precondition(
    !source.contains("TextField(") || !source.contains("viewModel.inputText"),
    "Expected today screen to have no natural-language input bound to the view model"
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
    !source.contains("today.startPlan"),
    "Expected the today screen to stop hosting its own Start Plan button"
)
precondition(
    dockSource.contains("today.startPlan") && dockSource.contains("DockPlanAction"),
    "Expected the dock's plan slot to host the Start Plan action"
)
precondition(
    contentViewSource.contains("today.start_training") && contentViewSource.contains("startPlanLiveWorkout"),
    "Expected ContentView to wire the dock Start Plan action to the live workout"
)
precondition(
    !source.contains("TrainingSessionScreen") && !source.contains("fullScreenCover"),
    "Expected the standalone training session screen to be merged into the today screen"
)
precondition(
    source.contains("isTrainingFocusActive") && source.contains("FocusExerciseCard"),
    "Expected the today screen to host the in-place focus training mode"
)
precondition(
    source.contains("scrollPosition") && source.contains("scrollTargetLayout"),
    "Expected focus mode to center the current exercise via scroll position"
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
