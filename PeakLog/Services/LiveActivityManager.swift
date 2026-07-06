import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

protocol PlanLiveActivityManaging {
    func start(session: PlanLiveWorkoutSession) async
    func update(session: PlanLiveWorkoutSession) async
    func end() async
    func consumeCompletedSetIds(sessionId: String) -> Set<String>
    /// 观察 Live Activity 内容更新，实时产出最新的已完成组 ID 集合。
    /// 用于 App 在前台时，用户从灵动岛/锁屏点击「完成动作」后即时刷新界面。
    func completedSetIdUpdates(sessionId: String) -> AsyncStream<Set<String>>
}

final class NoOpPlanLiveActivityManager: PlanLiveActivityManaging {
    func start(session: PlanLiveWorkoutSession) async {}
    func update(session: PlanLiveWorkoutSession) async {}
    func end() async {}
    func consumeCompletedSetIds(sessionId: String) -> Set<String> { [] }
    func completedSetIdUpdates(sessionId: String) -> AsyncStream<Set<String>> {
        AsyncStream { $0.finish() }
    }
}

#if canImport(ActivityKit)
@available(iOS 16.2, *)
final class LiveActivityManager: PlanLiveActivityManaging {
    static let shared = LiveActivityManager()

    private var activity: Activity<PlanLiveActivityAttributes>?

    private init() {}

    func start(session: PlanLiveWorkoutSession) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = attributes(from: session)
        PlanLiveActivitySharedStore.storeFocusedExerciseID(session.manualFocusExerciseId, sessionID: session.id)
        let state = PlanLiveActivityAttributes.contentState(
            for: attributes,
            completedSetIDs: Array(session.completedSetIds),
            focusedExerciseID: session.manualFocusExerciseId
        )

        do {
            // 结束系统里所有残留的计划 Activity（含 App 被杀前创建的），避免重复。
            for existing in Activity<PlanLiveActivityAttributes>.activities {
                await existing.end(dismissalPolicy: .immediate)
            }
            activity = nil

            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil, relevanceScore: 1),
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    func update(session: PlanLiveWorkoutSession) async {
        guard let activity = activeActivity(for: session.id) else { return }
        PlanLiveActivitySharedStore.storeFocusedExerciseID(session.manualFocusExerciseId, sessionID: session.id)
        let state = PlanLiveActivityAttributes.contentState(
            for: activity.attributes,
            completedSetIDs: Array(session.completedSetIds),
            focusedExerciseID: session.manualFocusExerciseId
        )
        await activity.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 1))
    }

    func end() async {
        guard let activity else { return }
        PlanLiveActivitySharedStore.storeFocusedExerciseID(nil, sessionID: activity.attributes.sessionID)
        await activity.end(dismissalPolicy: .immediate)
        self.activity = nil
    }

    func consumeCompletedSetIds(sessionId: String) -> Set<String> {
        PlanLiveActivitySharedStore.consumeCompletedSetIDs(sessionID: sessionId)
    }

    func completedSetIdUpdates(sessionId: String) -> AsyncStream<Set<String>> {
        AsyncStream { continuation in
            guard let activity = activeActivity(for: sessionId) else {
                continuation.finish()
                return
            }

            let task = Task {
                for await content in activity.contentUpdates {
                    continuation.yield(Set(content.state.completedSetIDs))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func activeActivity(for sessionID: String) -> Activity<PlanLiveActivityAttributes>? {
        if let activity, activity.attributes.sessionID == sessionID {
            return activity
        }

        activity = Activity<PlanLiveActivityAttributes>.activities.first {
            $0.attributes.sessionID == sessionID
        }
        return activity
    }

    private func attributes(from session: PlanLiveWorkoutSession) -> PlanLiveActivityAttributes {
        PlanLiveActivityAttributes(
            sessionID: session.id,
            title: session.title,
            focus: session.focus,
            exercises: session.exercises.map { exercise in
                PlanLiveActivityExerciseSnapshot(
                    id: exercise.id,
                    name: exercise.name,
                    sets: exercise.sets.map { set in
                        PlanLiveActivitySetSnapshot(
                            id: set.id,
                            setIndex: set.setIndex,
                            targetLoadText: liveActivityLoadText(for: set, loadType: exercise.loadType),
                            targetReps: set.targetReps
                        )
                    }
                )
            }
        )
    }

    private func liveActivityLoadText(for set: PlanLiveWorkoutSet, loadType: ExerciseLoadType) -> String {
        if let targetWeight = set.targetWeight {
            return "\(formatWeightValue(targetWeight)) \(set.targetWeightUnit.display)"
        }

        return loadType.displayLabel
    }
}
#endif

enum PlanLiveActivityManagerFactory {
    static func make() -> PlanLiveActivityManaging {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            return LiveActivityManager.shared
        }
        #endif

        return NoOpPlanLiveActivityManager()
    }
}
