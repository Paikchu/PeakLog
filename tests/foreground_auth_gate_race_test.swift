import Foundation

// `PeakLogApp` is the `@main App` struct — SwiftUI App types aren't practically
// instantiable/exercisable from XCTest (no existing test in this repo touches
// `PeakLogApp.swift` directly), so — following this repo's established convention
// for files that can't be driven through a normal test harness (see
// `plan_focus_training_mode_test.swift`) — this test inspects the source directly.

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/PeakLogApp.swift"),
    encoding: .utf8
)

// #36 — `.onChange(of: scenePhase, initial: true)` fires immediately on cold launch,
// which can race ahead of the `.task`'s `await authManager.restore()`. The foreground
// sync tick must be gated on the auth state actually being `.signedIn` rather than
// firing unconditionally.
precondition(
    appSource.contains("guard case .signedIn = authManager.state else { return }"),
    "Expected the foreground scenePhase handler to gate on authManager.state being .signedIn"
)

// Order matters: the auth-state guard must run before syncController.onForeground()
// is called, otherwise the gate doesn't actually prevent the race.
guard let guardRange = appSource.range(of: "guard case .signedIn = authManager.state else { return }"),
      let syncCallRange = appSource.range(of: "syncController.onForeground()")
else {
    preconditionFailure("Expected to find both the auth-state guard and the onForeground() call")
}
precondition(
    guardRange.lowerBound < syncCallRange.lowerBound,
    "Expected the auth-state guard to run before syncController.onForeground() is invoked"
)

// localizationManager.refreshFromSystem() should NOT be gated behind auth state —
// it's unrelated to the sync race and should run on every foreground transition.
guard let refreshRange = appSource.range(of: "localizationManager.refreshFromSystem()") else {
    preconditionFailure("Expected to find the localization refresh call")
}
precondition(
    refreshRange.lowerBound < guardRange.lowerBound,
    "Expected localizationManager.refreshFromSystem() to run unconditionally, before the auth-state guard"
)

print("foreground_auth_gate_race_test passed")
