import Foundation

#if canImport(ActivityKit)
import ActivityKit

nonisolated struct PlanLiveActivitySetSnapshot: Codable, Hashable, Sendable {
    let id: String
    let setIndex: Int
    let targetLoadText: String
    let targetReps: Int
}

nonisolated struct PlanLiveActivityExerciseSnapshot: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let sets: [PlanLiveActivitySetSnapshot]
}

nonisolated struct PlanLiveActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        let currentExerciseName: String
        /// 灵动岛紧凑态左槽用的 2–4 字简称，由 `PlanLiveActivityShortName` 算出。
        let currentExerciseShortName: String
        let currentPlanSetID: String?
        let currentSetIndex: Int
        /// 当前动作还剩几组没做——灵动岛的第一信息。
        ///
        /// 刻意随 state 下发而不是让 Widget 从 `attributes.exercises` 反推：
        /// `trimmedAttributes` 为了 4KB 预算会裁掉尾部动作，当前动作有可能根本
        /// 不在 attributes 里。
        let currentExerciseRemainingSets: Int
        /// 当前动作的总组数，展开态显示「第 3 组 / 共 4 组」。
        let currentExerciseTotalSets: Int
        let targetLoadText: String
        let targetReps: Int
        let completedSetIDs: [String]
        let completedSetsCount: Int
        let totalSetsCount: Int
        let isComplete: Bool

        init(
            currentExerciseName: String,
            currentExerciseShortName: String,
            currentPlanSetID: String?,
            currentSetIndex: Int,
            currentExerciseRemainingSets: Int,
            currentExerciseTotalSets: Int,
            targetLoadText: String,
            targetReps: Int,
            completedSetIDs: [String],
            completedSetsCount: Int,
            totalSetsCount: Int,
            isComplete: Bool
        ) {
            self.currentExerciseName = currentExerciseName
            self.currentExerciseShortName = currentExerciseShortName
            self.currentPlanSetID = currentPlanSetID
            self.currentSetIndex = currentSetIndex
            self.currentExerciseRemainingSets = currentExerciseRemainingSets
            self.currentExerciseTotalSets = currentExerciseTotalSets
            self.targetLoadText = targetLoadText
            self.targetReps = targetReps
            self.completedSetIDs = completedSetIDs
            self.completedSetsCount = completedSetsCount
            self.totalSetsCount = totalSetsCount
            self.isComplete = isComplete
        }

        enum CodingKeys: String, CodingKey {
            case currentExerciseName
            case currentExerciseShortName
            case currentPlanSetID
            case currentSetIndex
            case currentExerciseRemainingSets
            case currentExerciseTotalSets
            case targetLoadText
            case targetReps
            case completedSetIDs
            case completedSetsCount
            case totalSetsCount
            case isComplete
        }

        /// 新增字段一律 `decodeIfPresent` + 兜底。
        ///
        /// App 升级时系统里可能还留着上一版编码的 Activity。缺 key 直接抛错会让这个
        /// Activity 从 `Activity.activities` 里消失，而 `LiveActivityManager` 的
        /// update/end 都靠遍历那份注册表找 handle——结果就是灵动岛卡在旧内容上，
        /// App 既刷不新也结束不掉，只能等系统超时。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currentExerciseName = try container.decode(String.self, forKey: .currentExerciseName)
            currentPlanSetID = try container.decodeIfPresent(String.self, forKey: .currentPlanSetID)
            currentSetIndex = try container.decode(Int.self, forKey: .currentSetIndex)
            targetLoadText = try container.decode(String.self, forKey: .targetLoadText)
            targetReps = try container.decode(Int.self, forKey: .targetReps)
            completedSetIDs = try container.decode([String].self, forKey: .completedSetIDs)
            completedSetsCount = try container.decode(Int.self, forKey: .completedSetsCount)
            totalSetsCount = try container.decode(Int.self, forKey: .totalSetsCount)
            isComplete = try container.decode(Bool.self, forKey: .isComplete)

            currentExerciseShortName = try container.decodeIfPresent(
                String.self,
                forKey: .currentExerciseShortName
            ) ?? PlanLiveActivityShortName.make(from: currentExerciseName)
            currentExerciseTotalSets = try container.decodeIfPresent(
                Int.self,
                forKey: .currentExerciseTotalSets
            ) ?? 0
            currentExerciseRemainingSets = try container.decodeIfPresent(
                Int.self,
                forKey: .currentExerciseRemainingSets
            ) ?? 0
        }
    }

    let sessionID: String
    let title: String
    let focus: String?
    let exercises: [PlanLiveActivityExerciseSnapshot]
    /// 裁剪前的计划总组数。
    ///
    /// `exercises` 会被 `trimmedAttributes` 砍掉尾部动作，而完成集合覆盖整个 session：
    /// 拿裁剪后的 `totalSetsCount` 当分母会算出超过 100% 的进度（显示成 18/16，画成
    /// 转过头的进度环）。旧版本编码的 attributes 没有这个 key，按 nil 解码后回落到
    /// `totalSetsCount`。
    let plannedTotalSetsCount: Int?

    var totalSetsCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }

    /// 进度分母。取两者较大值，兼容旧 payload 与「裁剪后动作数反而更多」的不可能情况。
    var progressTotalSetsCount: Int {
        max(plannedTotalSetsCount ?? 0, totalSetsCount)
    }

    static func contentState(
        for attributes: PlanLiveActivityAttributes,
        completedSetIDs: [String],
        focusedExerciseID: String? = nil
    ) -> ContentState {
        let completed = Set(completedSetIDs)

        // 用户在 App 内手动聚焦的动作优先作为“当前动作”；聚焦动作做完后回落到顺序扫描。
        if let focusedExerciseID,
           let exercise = attributes.exercises.first(where: { $0.id == focusedExerciseID }),
           let set = exercise.sets.first(where: { !completed.contains($0.id) }) {
            return state(
                for: attributes,
                exercise: exercise,
                set: set,
                completed: completed
            )
        }

        for exercise in attributes.exercises {
            for set in exercise.sets where !completed.contains(set.id) {
                return state(
                    for: attributes,
                    exercise: exercise,
                    set: set,
                    completed: completed
                )
            }
        }

        let lastExercise = attributes.exercises.last
        let lastSet = lastExercise?.sets.last
        let name = lastExercise?.name ?? attributes.title
        return ContentState(
            currentExerciseName: name,
            currentExerciseShortName: PlanLiveActivityShortName.make(from: name),
            currentPlanSetID: nil,
            currentSetIndex: lastSet?.setIndex ?? 0,
            currentExerciseRemainingSets: 0,
            currentExerciseTotalSets: lastExercise?.sets.count ?? 0,
            targetLoadText: lastSet?.targetLoadText ?? "-",
            targetReps: lastSet?.targetReps ?? 0,
            completedSetIDs: Array(completed).sorted(),
            completedSetsCount: completed.count,
            totalSetsCount: attributes.progressTotalSetsCount,
            isComplete: true
        )
    }

    private static func state(
        for attributes: PlanLiveActivityAttributes,
        exercise: PlanLiveActivityExerciseSnapshot,
        set: PlanLiveActivitySetSnapshot,
        completed: Set<String>
    ) -> ContentState {
        ContentState(
            currentExerciseName: exercise.name,
            currentExerciseShortName: PlanLiveActivityShortName.make(from: exercise.name),
            currentPlanSetID: set.id,
            currentSetIndex: set.setIndex,
            currentExerciseRemainingSets: exercise.sets.count { !completed.contains($0.id) },
            currentExerciseTotalSets: exercise.sets.count,
            targetLoadText: set.targetLoadText,
            targetReps: set.targetReps,
            completedSetIDs: Array(completed).sorted(),
            completedSetsCount: completed.count,
            totalSetsCount: attributes.progressTotalSetsCount,
            isComplete: false
        )
    }
}

nonisolated enum PlanLiveActivitySharedStore {
    static let appGroupIdentifier = "group.com.max.PeakForm"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func storeCompletedSetIDs(_ setIDs: [String], sessionID: String) {
        defaults.set(Array(Set(setIDs)).sorted(), forKey: key(for: sessionID))
    }

    static func consumeCompletedSetIDs(sessionID: String) -> Set<String> {
        let key = key(for: sessionID)
        let values = defaults.stringArray(forKey: key) ?? []
        defaults.removeObject(forKey: key)
        return Set(values)
    }

    // 聚焦动作跨进程共享：App 内滑动切换后，锁屏 Intent 重建 state 时也要以聚焦动作为当前动作。
    static func storeFocusedExerciseID(_ exerciseID: String?, sessionID: String) {
        let key = focusedKey(for: sessionID)
        if let exerciseID {
            defaults.set(exerciseID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func readFocusedExerciseID(sessionID: String) -> String? {
        defaults.string(forKey: focusedKey(for: sessionID))
    }

    private static func key(for sessionID: String) -> String {
        "plan-live-activity.completed-set-ids.\(sessionID)"
    }

    private static func focusedKey(for sessionID: String) -> String {
        "plan-live-activity.focused-exercise-id.\(sessionID)"
    }
}
#endif
