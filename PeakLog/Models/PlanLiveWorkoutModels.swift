import Foundation

// 训练进行中（专注模式）的 session 值类型。从 `TodayWorkoutViewModel` 拆出并标记
// `nonisolated`：它们是纯数据，被 Live Activity 桥接、持久化恢复与总结计算
// （`TrainingSessionSummary`）在不同上下文里消费。
//
// 持久化兼容：session 会以 JSON 落盘（`today.live_workout_session.v1`），新增字段
// 必须是可选值，旧版本写入的数据缺 key 时按 nil 解码，不得导致恢复失败。

nonisolated struct PlanLiveWorkoutSet: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let setIndex: Int
    // 目标负重与次数在训练中可改（见 `TodayWorkoutViewModel.updateLiveWorkoutSet`）：
    // 计划是开练前的估计，实际做的才是要落库的那一份，而 confirm 时读的正是这份快照。
    var targetWeight: Double?
    var targetWeightUnit: WeightUnit
    var targetReps: Int
    let isAlreadyCompleted: Bool
}

nonisolated struct PlanLiveWorkoutExercise: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let loadType: ExerciseLoadType
    let sets: [PlanLiveWorkoutSet]
    /// 动作库 slug（可能为空，此时按名字匹配）；用于回查上次成绩。
    var exerciseId: String?
    // 训练中最需要的上下文：上次表现、教练建议与备注。来自计划动作，
    // 进入 session 时快照一份，专注卡片直接展示。
    // `previousPerformanceSummary` 计划侧目前恒为空，由 view model 在开练后
    // 从已落库的历史异步补齐。
    var previousPerformanceSummary: String?
    var aiSuggestion: String?
    var notes: String?
}

nonisolated struct PlanLiveWorkoutSession: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let focus: String?
    var exercises: [PlanLiveWorkoutExercise]
    var currentExerciseIndex: Int
    var currentSetIndex: Int
    var completedSetIds: Set<String>
    // 用户滑动锁定优先完成的动作；做完后清除，指针回到最早未完成动作。
    var manualFocusExerciseId: String?
    var skippedExerciseIds: Set<String> = []
    /// 开始训练的时刻，用于结束后的时长统计；旧版本持久化数据无此字段时为 nil。
    var startedAt: Date?

    var currentExercise: PlanLiveWorkoutExercise? {
        guard exercises.indices.contains(currentExerciseIndex) else { return nil }
        return exercises[currentExerciseIndex]
    }

    var currentSet: PlanLiveWorkoutSet? {
        guard let currentExercise, currentExercise.sets.indices.contains(currentSetIndex) else { return nil }
        return currentExercise.sets[currentSetIndex]
    }

    var completedSetsCount: Int {
        completedSetIds.count
    }

    var totalSetsCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }

    var progress: Double {
        guard totalSetsCount > 0 else { return 0 }
        return Double(completedSetsCount) / Double(totalSetsCount)
    }

    var isComplete: Bool {
        completedSetsCount >= totalSetsCount
    }

    func exercise(withId id: String) -> PlanLiveWorkoutExercise? {
        exercises.first { $0.id == id }
    }

    func firstIncompleteSetIndex(in exercise: PlanLiveWorkoutExercise) -> Int? {
        exercise.sets.firstIndex { !completedSetIds.contains($0.id) }
    }

    func completedSetsCount(in exercise: PlanLiveWorkoutExercise) -> Int {
        exercise.sets.count { completedSetIds.contains($0.id) }
    }

    func isExerciseComplete(_ exercise: PlanLiveWorkoutExercise) -> Bool {
        firstIncompleteSetIndex(in: exercise) == nil
    }
}
