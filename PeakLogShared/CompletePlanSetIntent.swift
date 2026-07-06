import Foundation

#if canImport(ActivityKit) && canImport(AppIntents)
import ActivityKit
import AppIntents

/// Live Activity 上「完成动作」按钮触发的 Intent。
///
/// 重要：`LiveActivityIntent` 的 `perform()` 由系统路由到 **主 App 进程** 执行，
/// 因此该类型必须同时编译进主 App target 与 Widget Extension target。
/// 它被放在 `PeakLogShared/` 目录下正是为了让两个 target 都包含它——
/// 若只属于扩展 target，主 App 二进制里找不到此类型，点击会静默失败。
struct CompletePlanSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "完成动作"
    static let openAppWhenRun = false

    @Parameter(title: "Activity ID")
    var activityID: String

    @Parameter(title: "Plan Set ID")
    var planSetID: String

    init() {
        activityID = ""
        planSetID = ""
    }

    init(activityID: String, planSetID: String) {
        self.activityID = activityID
        self.planSetID = planSetID
    }

    func perform() async throws -> some IntentResult {
        guard !activityID.isEmpty,
              let activity = Activity<PlanLiveActivityAttributes>.activities.first(where: {
                  $0.attributes.sessionID == activityID
              }) else {
            return .result()
        }

        var completedSetIDs = Set(activity.content.state.completedSetIDs)
        if !planSetID.isEmpty {
            completedSetIDs.insert(planSetID)
        }

        let sortedSetIDs = Array(completedSetIDs).sorted()
        let state = PlanLiveActivityAttributes.contentState(
            for: activity.attributes,
            completedSetIDs: sortedSetIDs,
            focusedExerciseID: PlanLiveActivitySharedStore.readFocusedExerciseID(sessionID: activityID)
        )
        PlanLiveActivitySharedStore.storeCompletedSetIDs(sortedSetIDs, sessionID: activityID)
        await activity.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 1))

        return .result()
    }
}
#endif
