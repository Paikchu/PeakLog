import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let screenSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Today/TodayWorkoutScreen.swift"),
    encoding: .utf8
)
let componentsSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Today/TrainingFocusComponents.swift"),
    encoding: .utf8
)
let viewModelSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/ViewModels/TodayWorkoutViewModel.swift"),
    encoding: .utf8
)
let contentViewSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/ContentView.swift"),
    encoding: .utf8
)
let trainingActionSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Home/TrainingActionLayer.swift"),
    encoding: .utf8
)
let attributesSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLogShared/PlanLiveActivityAttributes.swift"),
    encoding: .utf8
)

precondition(
    !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("PeakLog/Views/Today/TrainingSessionScreen.swift").path),
    "Expected the standalone TrainingSessionScreen to be deleted"
)
precondition(
    viewModelSource.contains("var manualFocusExerciseId") && viewModelSource.contains("var skippedExerciseIds"),
    "Expected the live session to track the manually focused exercise and skipped exercises"
)
precondition(
    viewModelSource.contains("func focusLiveExercise") && viewModelSource.contains("func skipCurrentLiveExercise"),
    "Expected the view model to expose swipe-to-focus and skip-exercise actions"
)
precondition(
    viewModelSource.contains("func minimizeTrainingFocus") && viewModelSource.contains("func resumeTrainingFocus"),
    "Expected focus mode to be minimizable without losing the session"
)
precondition(
    viewModelSource.contains("restoreLiveWorkoutSessionIfNeeded") && viewModelSource.contains("persistActiveLiveWorkout"),
    "Expected the live session to persist across app restarts within the same day"
)
precondition(
    viewModelSource.contains("restEndDate") && viewModelSource.contains("restDurationSeconds"),
    "Expected a between-set rest countdown"
)
precondition(
    screenSource.contains("focusLiveExercise") && screenSource.contains("displayedExerciseId"),
    "Expected scroll-settle to focus the centered exercise"
)
precondition(
    screenSource.contains("isIdleTimerDisabled"),
    "Expected the screen to stay awake during focus training"
)
precondition(
    screenSource.contains("accessibilityReduceMotion"),
    "Expected focus animations to degrade under Reduce Motion"
)
precondition(
    componentsSource.contains("TrainingFocusBar") && componentsSource.contains("training_session.complete_set"),
    "Expected a bottom bar with the big complete-current-set action"
)
precondition(
    !componentsSource.contains(".glassActionBackground"),
    "Expected focus-mode primary actions to avoid the system glass rim"
)
precondition(
    componentsSource.contains(".background(Color.accentPrimary.opacity(0.82), in: Capsule())"),
    "Expected complete-set action to use a solid amber capsule"
)
precondition(
    componentsSource.contains(".background(Color.green.opacity(0.82), in: Capsule())"),
    "Expected finish action to use a solid green capsule"
)
precondition(
    contentViewSource.contains("TrainingFocusBar") && trainingActionSource.contains("training_session.resume"),
    "Expected the tab bar to swap with the focus bar and offer resume for minimized sessions"
)
precondition(
    attributesSource.contains("focusedExerciseID"),
    "Expected the Live Activity to follow the manually focused exercise"
)

print("plan_focus_training_mode_test passed")
