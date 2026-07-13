import Foundation

// `TodayWorkoutViewModel.swift` pulls in a large dependency graph (training plan /
// workout services, models spread across many files), so — following this repo's
// existing convention for view-model files too heavy to compile standalone via
// `swiftc` (see `plan_focus_training_mode_test.swift`) — this test inspects the
// source directly. The actual runtime behavior (debounced write lands, restore sees
// it) is covered by `PeakLogTests/TodayWorkoutFocusFlowTests.testSessionPersistsAndRestoresMinimizedOnSameDay`
// under `xcodebuild test`. This guards the structural shape of the #18 fix.

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let viewModelSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/ViewModels/TodayWorkoutViewModel.swift"),
    encoding: .utf8
)

// #18 — every `activeLiveWorkout` mutation used to synchronously run
// JSONEncoder().encode + UserDefaults.set on the main thread via didSet. That must
// now go through a debounced scheduler instead of firing `persistActiveLiveWorkout()`
// directly from didSet.
precondition(
    viewModelSource.contains("didSet { schedulePersistActiveLiveWorkout() }"),
    "Expected activeLiveWorkout's didSet to debounce persistence instead of persisting synchronously"
)
precondition(
    viewModelSource.contains("private var persistDebounceTask: Task<Void, Never>?"),
    "Expected a cancellable debounce task so rapid successive writes collapse into one"
)
precondition(
    viewModelSource.contains("persistDebounceTask?.cancel()") && viewModelSource.contains("try? await Task.sleep(for: Self.persistDebounceDelay)"),
    "Expected schedulePersistActiveLiveWorkout to cancel any pending write and delay the real one"
)

// Critical checkpoints (start/confirm/cancel) must flush immediately rather than
// risk losing state if the app is killed inside the debounce window.
precondition(
    viewModelSource.contains("private func persistActiveLiveWorkoutImmediately()"),
    "Expected an immediate-flush path that bypasses the debounce for critical checkpoints"
)

func immediateFlushIsCalled(inFunctionNamed name: String) -> Bool {
    guard let funcRange = viewModelSource.range(of: "func \(name)") else { return false }
    let afterFunc = viewModelSource[funcRange.upperBound...]
    // Look within a reasonable window (this function's body) for the immediate-flush call.
    let window = afterFunc.prefix(2_000)
    return window.contains("persistActiveLiveWorkoutImmediately()")
}

precondition(
    immediateFlushIsCalled(inFunctionNamed: "startPlanLiveWorkout()"),
    "Expected startPlanLiveWorkout() to persist immediately (critical checkpoint)"
)
precondition(
    immediateFlushIsCalled(inFunctionNamed: "cancelPlanLiveWorkout()"),
    "Expected cancelPlanLiveWorkout() to persist immediately (critical checkpoint)"
)
precondition(
    immediateFlushIsCalled(inFunctionNamed: "confirmPlanLiveWorkout() async"),
    "Expected confirmPlanLiveWorkout() to persist immediately (critical checkpoint)"
)

print("today_workout_persist_debounce_test passed")
