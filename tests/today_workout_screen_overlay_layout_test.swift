import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = rootURL.appendingPathComponent("PeakLog/Views/Today/TodayWorkoutScreen.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)
let viewModelSourceURL = rootURL.appendingPathComponent("PeakLog/ViewModels/TodayWorkoutViewModel.swift")
let viewModelSource = try String(contentsOf: viewModelSourceURL, encoding: .utf8)
let contentViewSourceURL = rootURL.appendingPathComponent("PeakLog/ContentView.swift")
let contentViewSource = try String(contentsOf: contentViewSourceURL, encoding: .utf8)
let actionLayerSourceURL = rootURL.appendingPathComponent("PeakLog/Views/Home/TrainingActionLayer.swift")
let actionLayerSource = try String(contentsOf: actionLayerSourceURL, encoding: .utf8)

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
    !source.contains("DailyRecordSheet"),
    "Expected the manual daily record entry point to be removed from the today screen"
)
precondition(
    !source.contains("PlanComposerSheet"),
    "Expected floating plus to stop presenting the free-form plan composer"
)
precondition(
    source.contains("today.addPlanExercise") && !source.contains("today.addRecordMenu"),
    "Expected the inline add row to expose only the add-to-plan action, with no floating add menu"
)
precondition(
    !source.contains("today.startPlan"),
    "Expected the today screen to stop hosting its own Start Plan button"
)
precondition(
    !contentViewSource.contains("HomeDockBar") && contentViewSource.contains("TabView(selection: $selectedTab)"),
    "Expected native tab navigation with no custom dock CTA slot"
)
precondition(
    actionLayerSource.contains("today.startPlan") && actionLayerSource.contains("training_focus.resumeBanner"),
    "Expected the training action layer above the dock to host both start and resume states"
)
precondition(
    contentViewSource.contains("TrainingActionLayer") && contentViewSource.contains("startPlanLiveWorkout"),
    "Expected ContentView to wire the training action layer to the live workout"
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
