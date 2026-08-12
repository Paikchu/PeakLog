import Foundation

// `TodayWorkoutViewModel.swift` pulls in a large dependency graph (training plan /
// workout services, models spread across many files), so — following this repo's
// existing convention for view-model files too heavy to compile standalone via
// `swiftc` (see `plan_focus_training_mode_test.swift`) — this test inspects the
// source directly. The actual runtime behavior (debounced write lands, restore sees
// it, and the flush-on-background hook forces a pending write immediately) is
// covered by `PeakLogTests/TodayWorkoutFocusFlowTests`
// (`testSessionPersistsAndRestoresMinimizedOnSameDay` and
// `testFlushPendingLiveWorkoutPersistenceLandsDebouncedWriteImmediately`) under
// `xcodebuild test`. This guards the structural shape of the #18 fix.

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let viewModelSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/ViewModels/TodayWorkoutViewModel.swift"),
    encoding: .utf8
)
let contentViewSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/ContentView.swift"),
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

/// 取出 `name` 这个函数的函数体(第一个 `{` 到与之配对的 `}`)。
///
/// 这里刻意做真正的花括号配对,而不是"签名之后取 N 个字符"。原先的版本取 2000
/// 字符窗口,#168 往 `confirmPlanLiveWorkout()` 里加了一次 `await
/// flushPendingPlanSetTargets()` 和几行注释,就把 flush 调用挤到了 2037 字符处 ——
/// 断言变红,但被断言的那行代码一直好好地待在函数里。窗口式扫描的红/绿取决于
/// 函数有多长,那不是这个测试想守的东西。
func body(ofFunctionNamed name: String) -> Substring? {
    guard let signature = viewModelSource.range(of: "func \(name)") else { return nil }
    guard let open = viewModelSource[signature.upperBound...].firstIndex(of: "{") else { return nil }

    var depth = 0
    var index = open
    while index < viewModelSource.endIndex {
        switch viewModelSource[index] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return viewModelSource[viewModelSource.index(after: open)..<index]
            }
        default: break
        }
        index = viewModelSource.index(after: index)
    }
    return nil
}

func immediateFlushIsCalled(inFunctionNamed name: String) -> Bool {
    guard let body = body(ofFunctionNamed: name) else { return false }
    return body.contains("persistActiveLiveWorkoutImmediately()")
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

// Regression guard: the debounce window has no value if nothing ever forces a
// pending write to land before the app can be backgrounded/killed. There must be
// a public flush entry point, and ContentView (which already observes
// scenePhase) must call it when the scene goes inactive/background — not just
// on `.active`, which is all it handled before this fix.
precondition(
    viewModelSource.contains("func flushPendingLiveWorkoutPersistence()"),
    "Expected a public flush method the hosting view can call before backgrounding"
)
precondition(
    contentViewSource.contains(".inactive, .background:") && contentViewSource.contains("todayViewModel.flushPendingLiveWorkoutPersistence()"),
    "Expected ContentView's scenePhase observer to flush pending live-workout persistence on .inactive/.background, not just handle .active"
)

print("today_workout_persist_debounce_test passed")
