import Foundation

// `LiveActivityManager` is `#if canImport(ActivityKit)`-gated and ActivityKit isn't
// available to a plain host `swiftc` invocation, so — following the existing
// convention for ActivityKit-adjacent files (see `plan_focus_training_mode_test.swift`
// asserting on `PlanLiveActivityAttributes.swift` as text) — this test inspects the
// source directly rather than compiling and exercising the class. It guards the three
// fixes for issues #11 / #12 / #37 against silent regressions.

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let managerSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Services/LiveActivityManager.swift"),
    encoding: .utf8
)

// #11 — the class touches `Activity.request/update/end` and mutates `self.activity`;
// it must be pinned to the main actor so concurrent callers can't race on that state.
precondition(
    managerSource.contains("@MainActor\nfinal class LiveActivityManager"),
    "Expected LiveActivityManager to be @MainActor-isolated"
)
// The factory vends `LiveActivityManager.shared`, a main-actor-isolated static
// property, so it must itself be main-actor-isolated to reference it synchronously.
precondition(
    managerSource.contains("@MainActor\n    static func make() -> PlanLiveActivityManaging"),
    "Expected PlanLiveActivityManagerFactory.make() to be @MainActor-isolated"
)

// #12 — large plans must not silently fail to start, and the payload must be kept
// under Apple's combined attributes+content-state size budget.
precondition(
    managerSource.contains("attributesSizeBudgetBytes"),
    "Expected a size budget constant guarding Activity.request's ~4KB payload limit"
)
precondition(
    managerSource.contains("trimmedAttributes") && managerSource.contains("candidateExercises.removeLast()"),
    "Expected oversized attributes to be trimmed by dropping trailing exercises rather than failing outright"
)
precondition(
    !managerSource.contains("catch {\n            activity = nil\n        }"),
    "Expected the Activity.request failure path to no longer be a bare silent catch"
)
precondition(
    managerSource.contains("Self.logger.error(\"Activity.request failed"),
    "Expected Activity.request failures to be reported via the logger instead of swallowed"
)

// #37 — `start` must refuse to tear down an existing (possibly still-valid) system
// Activity when handed a session with no exercise data (e.g. restore raced ahead of
// the local database after a kill+relaunch).
precondition(
    managerSource.contains("guard !session.exercises.isEmpty else"),
    "Expected start(session:) to bail out before ending existing activities when exercises are empty"
)

// Order matters: the empty-exercises guard must run before the teardown loop that
// ends existing system activities, otherwise a stale/empty session would still wipe
// out a valid in-flight Activity.
if let guardRange = managerSource.range(of: "guard !session.exercises.isEmpty else"),
   let teardownRange = managerSource.range(of: "for existing in Activity<PlanLiveActivityAttributes>.activities") {
    precondition(
        guardRange.lowerBound < teardownRange.lowerBound,
        "Expected the empty-exercises guard to run before existing activities are torn down"
    )
} else {
    preconditionFailure("Expected to find both the empty-exercises guard and the activity teardown loop")
}

print("live_activity_manager_safety_test passed")
