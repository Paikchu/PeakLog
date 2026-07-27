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
        let currentPlanSetID: String?
        let currentSetIndex: Int
        let targetLoadText: String
        let targetReps: Int
        let completedSetIDs: [String]
        let completedSetsCount: Int
        let totalSetsCount: Int
        let isComplete: Bool
    }

    let sessionID: String
    let title: String
    let focus: String?
    let exercises: [PlanLiveActivityExerciseSnapshot]

    var totalSetsCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
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
            return ContentState(
                currentExerciseName: exercise.name,
                currentPlanSetID: set.id,
                currentSetIndex: set.setIndex,
                targetLoadText: set.targetLoadText,
                targetReps: set.targetReps,
                completedSetIDs: Array(completed).sorted(),
                completedSetsCount: completed.count,
                totalSetsCount: attributes.totalSetsCount,
                isComplete: false
            )
        }

        for exercise in attributes.exercises {
            for set in exercise.sets where !completed.contains(set.id) {
                return ContentState(
                    currentExerciseName: exercise.name,
                    currentPlanSetID: set.id,
                    currentSetIndex: set.setIndex,
                    targetLoadText: set.targetLoadText,
                    targetReps: set.targetReps,
                    completedSetIDs: Array(completed).sorted(),
                    completedSetsCount: completed.count,
                    totalSetsCount: attributes.totalSetsCount,
                    isComplete: false
                )
            }
        }

        let lastExercise = attributes.exercises.last
        let lastSet = lastExercise?.sets.last
        return ContentState(
            currentExerciseName: lastExercise?.name ?? attributes.title,
            currentPlanSetID: nil,
            currentSetIndex: lastSet?.setIndex ?? 0,
            targetLoadText: lastSet?.targetLoadText ?? "-",
            targetReps: lastSet?.targetReps ?? 0,
            completedSetIDs: Array(completed).sorted(),
            completedSetsCount: completed.count,
            totalSetsCount: attributes.totalSetsCount,
            isComplete: true
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
