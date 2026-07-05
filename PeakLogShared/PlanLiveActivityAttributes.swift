import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct PlanLiveActivitySetSnapshot: Codable, Hashable {
    let id: String
    let setIndex: Int
    let targetLoadText: String
    let targetReps: Int
}

struct PlanLiveActivityExerciseSnapshot: Codable, Hashable {
    let id: String
    let name: String
    let sets: [PlanLiveActivitySetSnapshot]
}

struct PlanLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
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
        completedSetIDs: [String]
    ) -> ContentState {
        let completed = Set(completedSetIDs)

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

enum PlanLiveActivitySharedStore {
    static let appGroupIdentifier = "group.com.max.PeakLog"

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

    private static func key(for sessionID: String) -> String {
        "plan-live-activity.completed-set-ids.\(sessionID)"
    }
}
#endif
