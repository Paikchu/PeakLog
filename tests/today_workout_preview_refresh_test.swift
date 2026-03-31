import Foundation

let sourceURL = URL(fileURLWithPath: "/Users/max/Developer/IOS/PeakLog/PeakLog/ViewModels/TodayWorkoutViewModel.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)

precondition(
    source.contains("case .workoutPreview(let block):"),
    "Expected workout preview events to carry the preview block into the state machine"
)
precondition(
    source.contains("applyStreamingWorkoutPreview(block)"),
    "Expected workout preview events to update the home-page record immediately"
)
precondition(
    source.contains("schedulePersistenceFallback(refreshScope: .recordOnly)"),
    "Expected workout preview events to trigger a fallback refresh instead of waiting only for SSE completion"
)
precondition(
    source.contains("self.isSending = false"),
    "Expected the fallback path to release the sending lock if the stream tail lags"
)

print("today_workout_preview_refresh_test passed")
