import Foundation
import os

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
    // 显式声明为非隔离 init：本类无状态、无副作用，且作为
    // `TodayWorkoutViewModel` 指定 init 的默认参数 `NoOpPlanLiveActivityManager()` 使用，
    // 而默认参数在“非隔离上下文”中求值。若沿用编译器推断的 @MainActor init 会触发
    // “在同步非隔离上下文中调用 Main Actor 隔离的初始化器”告警，故此处显式 nonisolated。
    nonisolated init() {}
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
@MainActor
final class LiveActivityManager: PlanLiveActivityManaging {
    static let shared = LiveActivityManager()

    /// `Activity.request` counts `attributes` + the initial `ContentState` together
    /// against Apple's ~4KB payload budget. Leave headroom under the hard limit so a
    /// day with many exercises/sets doesn't tip over it.
    private static let attributesSizeBudgetBytes = 3_500

    private static let logger = Logger(subsystem: "com.max.PeakLog", category: "LiveActivityManager")

    private var activity: Activity<PlanLiveActivityAttributes>?

    private init() {}

    func start(session: PlanLiveWorkoutSession) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // 防御：调用方本应确保 session 数据在调用前已是最新（例如 App 被杀后重启，
        // 等本地数据库恢复当日计划后再调用 start），但这里再兜底一次——如果传入的
        // session 还没有动作数据，直接跳过，避免清空并用空快照重建系统里已存在、
        // 可能仍然有效的 Activity。
        guard !session.exercises.isEmpty else {
            Self.logger.error("start(session:) called with no exercises (sessionID \(session.id, privacy: .private)); skipping to avoid clobbering an existing Live Activity with stale/empty data")
            return
        }

        let attributes = attributes(from: session)
        PlanLiveActivitySharedStore.storeFocusedExerciseID(session.manualFocusExerciseId, sessionID: session.id)
        let state = PlanLiveActivityAttributes.contentState(
            for: attributes,
            completedSetIDs: Array(session.completedSetIds),
            focusedExerciseID: session.manualFocusExerciseId
        )

        // 结束系统里所有残留的计划 Activity（含 App 被杀前创建的），避免重复。
        for existing in Activity<PlanLiveActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil, relevanceScore: 1),
                pushType: nil
            )
        } catch {
            activity = nil
            // 曾经在这里静默吞掉：灵动岛/锁屏不显示且后续 update 全部因 activeActivity(for:)
            // 找不到匹配而 return，用户毫无感知。现在至少上报到统一日志，便于用 Console.app
            // 或 sysdiagnose 定位大计划导致的启动失败。
            Self.logger.error("Activity.request failed for sessionID \(session.id, privacy: .private): \(String(describing: error))")
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
        await Self.systemHandle(id: activity.id)?
            .update(ActivityContent(state: state, staleDate: nil, relevanceScore: 1))
    }

    func end() async {
        guard let activity else { return }
        PlanLiveActivitySharedStore.storeFocusedExerciseID(nil, sessionID: activity.attributes.sessionID)
        await Self.systemHandle(id: activity.id)?.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    /// Re-reads the handle for an activity out of ActivityKit's own registry.
    ///
    /// `Activity` is not `Sendable`, and `update`/`end` are async methods that
    /// run off the caller's actor. Passing them the instance cached in
    /// `self.activity` therefore means sending a main-actor-isolated value into
    /// concurrently-executing code — an error in the Swift 6 language mode, and
    /// not a spurious one: nothing stops the main actor from touching that same
    /// object while the call is in flight.
    ///
    /// `Activity.activities` is nonisolated and owned by the system, so the
    /// handle it hands back was never part of the main actor's region and can be
    /// sent freely. That also matches who actually owns the live activity:
    /// ActivityKit does, and `self.activity` is only a cache of which one is
    /// ours. A handle that is no longer in the registry (the user or the system
    /// dismissed it) yields `nil`, which is exactly the no-op the old code got
    /// from calling `end`/`update` on a dead activity.
    ///
    /// Keyed by `id` (a `String`) rather than by the cached instance on purpose:
    /// passing the non-`Sendable` instance in would pull the result back into
    /// the main actor's region and defeat the point.
    private nonisolated static func systemHandle(
        id: String
    ) -> Activity<PlanLiveActivityAttributes>? {
        Activity<PlanLiveActivityAttributes>.activities.first { $0.id == id }
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
        let exercises = session.exercises.map { exercise in
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

        return trimmedAttributes(
            sessionID: session.id,
            title: session.title,
            focus: session.focus,
            exercises: exercises,
            // 裁剪前的真实总数：裁掉的动作里可能已经有完成的组，用裁剪后的数字当分母
            // 会把进度算成超过 100%。
            plannedTotalSetsCount: session.totalSetsCount
        )
    }

    /// Drops trailing exercises — the ones least likely to be "current" soonest —
    /// one at a time until the encoded attributes fit under `attributesSizeBudgetBytes`.
    /// Always keeps at least the first exercise so `contentState(for:...)` still has
    /// something to compute against; if that alone doesn't fit, ships it anyway (a
    /// slightly-oversized Activity beats none, and `Activity.request` failing is now
    /// logged rather than silently swallowed).
    private func trimmedAttributes(
        sessionID: String,
        title: String,
        focus: String?,
        exercises: [PlanLiveActivityExerciseSnapshot],
        plannedTotalSetsCount: Int
    ) -> PlanLiveActivityAttributes {
        var candidateExercises = exercises
        while true {
            let candidate = PlanLiveActivityAttributes(
                sessionID: sessionID,
                title: title,
                focus: focus,
                exercises: candidateExercises,
                plannedTotalSetsCount: plannedTotalSetsCount
            )

            let encodedSize = (try? JSONEncoder().encode(candidate).count) ?? 0
            let fitsBudget = encodedSize <= Self.attributesSizeBudgetBytes

            if fitsBudget || candidateExercises.count <= 1 {
                if !fitsBudget {
                    Self.logger.warning("Live Activity attributes still ~\(encodedSize) bytes after trimming to \(candidateExercises.count) exercise(s) for sessionID \(sessionID, privacy: .private); Activity.request may still fail")
                } else if candidateExercises.count < exercises.count {
                    Self.logger.info("Trimmed Live Activity attributes from \(exercises.count) to \(candidateExercises.count) exercise(s) to stay under the size budget for sessionID \(sessionID, privacy: .private)")
                }
                return candidate
            }

            candidateExercises.removeLast()
        }
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
    @MainActor
    static func make() -> PlanLiveActivityManaging {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            return LiveActivityManager.shared
        }
        #endif

        return NoOpPlanLiveActivityManager()
    }
}
