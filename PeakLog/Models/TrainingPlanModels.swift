import Foundation

nonisolated enum PlanItemType: String, Codable, Equatable, Sendable {
    case strength
    case cardio
}

nonisolated enum ExerciseLoadType: String, Codable, Equatable, Sendable {
    case bodyweight
    case weighted
    case unknown

    var displayLabel: String {
        switch self {
        case .bodyweight:
            return String(localized: "chat.exercise.bodyweight")
        case .weighted:
            return String(localized: "plan.load.weighted_placeholder")
        case .unknown:
            return String(localized: "plan.load.unset")
        }
    }
}

nonisolated struct TrainingPlanSet: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var setIndex: Int
    var targetWeight: Double?
    var targetWeightUnit: WeightUnit
    var targetReps: Int
    var completedAt: Date?
    var linkedExerciseSetId: String?

    var isCompleted: Bool {
        completedAt != nil || linkedExerciseSetId != nil
    }
}

/// 一次性调节某个计划动作下多组的目标。重量与次数互相独立：某一维是 `nil`
/// 就表示「这一维不动」，所以同一个类型既能表达「只改重量」也能表达「只改次数」。
///
/// 为什么不逐组调 `updatePlannedSet`：那组参数描述的是「某一组的最终值」，
/// 循环 N 次等于 N 次落库、N 次云推送，中途失败还会留下改了一半的动作。
/// 批量语义要的正是一次写入、要么全改要么不改。
nonisolated struct PlannedSetBatchAdjustment: Equatable, Sendable {
    /// 重量怎么改。单独建模而不是直接传 `Double?`：`nil` 在 `targetWeight` 里
    /// 已经表示「自重 / 未设定」，没法再兼职表示「不改」。
    enum WeightChange: Equatable, Sendable {
        /// 所有组统一写成同一个目标；`nil` 表示自重（清空重量）。单位一并写入。
        case uniform(Double?, unit: WeightUnit)
        /// 在每组各自的当前重量上加减，保留 45/52/55 这类递增结构。增量按每组
        /// 自己的 `targetWeightUnit` 计（同一动作内不会混单位：单位在建组时由
        /// 用户偏好统一写入）；自重组（`targetWeight == nil`）不受影响。
        case delta(Double)
    }

    /// 次数怎么改，两个 case 与 `WeightChange` 一一对应。
    enum RepsChange: Equatable, Sendable {
        case uniform(Int)
        case delta(Int)
    }

    var weight: WeightChange? = nil
    var reps: RepsChange? = nil

    /// 两维都不改。调用方与本地库都据此短路成 no-op，不写盘也不记编辑事件。
    var isEmpty: Bool { weight == nil && reps == nil }

    /// 把本次调节应用到一组目标上。刻意做成纯函数：写库路径和 ViewModel 的
    /// 乐观更新共用同一份规则，界面先显示的值不会和最终落库的值算成两样。
    ///
    /// 下界（重量 ≥ 0、次数 ≥ 1）不在这里另起一套，一律走 `QuickSetAdjustment`
    /// 的钳制——训练中的 ± 快速调整、单组编辑与这里的批量调节必须共用同一份取值
    /// 规则，否则同一个动作会因为入口不同而落在不同的边界上。
    func applied(to set: TrainingPlanSet) -> TrainingPlanSet {
        var result = set
        if let weight {
            switch weight {
            case .uniform(let value, let unit):
                result.targetWeight = QuickSetAdjustment.clampedWeight(value)
                result.targetWeightUnit = unit
            case .delta(let amount):
                if let current = set.targetWeight {
                    result.targetWeight = QuickSetAdjustment.clampedWeight(current + amount)
                }
            }
        }
        if let reps {
            switch reps {
            case .uniform(let value):
                result.targetReps = QuickSetAdjustment.clampedReps(value)
            case .delta(let amount):
                result.targetReps = QuickSetAdjustment.clampedReps(set.targetReps + amount)
            }
        }
        return result
    }
}

nonisolated struct TrainingPlanExercise: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var orderIndex: Int
    let exerciseName: String
    /// Stable library slug; nil for legacy free-text entries.
    var exerciseId: String?
    let exerciseLoadType: ExerciseLoadType
    let progressionMode: String
    let notes: String?
    var previousPerformanceSummary: String?
    var aiSuggestion: String?
    var sets: [TrainingPlanSet]
    var itemType: PlanItemType
    var cardioActivityType: CardioActivityType?
    var targetDurationMinutes: Int?
    var targetDistanceKm: Double?
    var targetRPE: Double?
    var cardioCompletedAt: Date?
    var linkedCardioWorkoutId: String?

    init(
        id: String,
        orderIndex: Int,
        exerciseName: String,
        exerciseId: String? = nil,
        exerciseLoadType: ExerciseLoadType,
        progressionMode: String,
        notes: String?,
        previousPerformanceSummary: String?,
        aiSuggestion: String?,
        sets: [TrainingPlanSet],
        itemType: PlanItemType = .strength,
        cardioActivityType: CardioActivityType? = nil,
        targetDurationMinutes: Int? = nil,
        targetDistanceKm: Double? = nil,
        targetRPE: Double? = nil,
        cardioCompletedAt: Date? = nil,
        linkedCardioWorkoutId: String? = nil
    ) {
        self.id = id
        self.orderIndex = orderIndex
        self.exerciseName = exerciseName
        self.exerciseId = exerciseId
        self.exerciseLoadType = exerciseLoadType
        self.progressionMode = progressionMode
        self.notes = notes
        self.previousPerformanceSummary = previousPerformanceSummary
        self.aiSuggestion = aiSuggestion
        self.sets = sets
        self.itemType = itemType
        self.cardioActivityType = cardioActivityType
        self.targetDurationMinutes = targetDurationMinutes
        self.targetDistanceKm = targetDistanceKm
        self.targetRPE = targetRPE
        self.cardioCompletedAt = cardioCompletedAt
        self.linkedCardioWorkoutId = linkedCardioWorkoutId
    }

    var isCardioCompleted: Bool {
        itemType == .cardio && (cardioCompletedAt != nil || linkedCardioWorkoutId != nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, orderIndex, exerciseName, exerciseId, exerciseLoadType, progressionMode, notes
        case previousPerformanceSummary, aiSuggestion, sets, itemType, cardioActivityType
        case targetDurationMinutes, targetDistanceKm, targetRPE, cardioCompletedAt, linkedCardioWorkoutId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        orderIndex = try container.decode(Int.self, forKey: .orderIndex)
        exerciseName = try container.decode(String.self, forKey: .exerciseName)
        exerciseId = try container.decodeIfPresent(String.self, forKey: .exerciseId)
        exerciseLoadType = try container.decode(ExerciseLoadType.self, forKey: .exerciseLoadType)
        progressionMode = try container.decode(String.self, forKey: .progressionMode)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        previousPerformanceSummary = try container.decodeIfPresent(String.self, forKey: .previousPerformanceSummary)
        aiSuggestion = try container.decodeIfPresent(String.self, forKey: .aiSuggestion)
        sets = try container.decodeIfPresent([TrainingPlanSet].self, forKey: .sets) ?? []
        itemType = try container.decodeIfPresent(PlanItemType.self, forKey: .itemType) ?? .strength
        let rawCardioActivityType = try container.decodeIfPresent(String.self, forKey: .cardioActivityType)
        cardioActivityType = rawCardioActivityType.flatMap(CardioActivityType.init(rawValue:))
            ?? (itemType == .cardio ? .running : nil)
        targetDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .targetDurationMinutes)
        targetDistanceKm = try container.decodeIfPresent(Double.self, forKey: .targetDistanceKm)
        targetRPE = try container.decodeIfPresent(Double.self, forKey: .targetRPE)
        cardioCompletedAt = try container.decodeIfPresent(Date.self, forKey: .cardioCompletedAt)
        linkedCardioWorkoutId = try container.decodeIfPresent(String.self, forKey: .linkedCardioWorkoutId)
    }
}

nonisolated struct TrainingPlanDay: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let planDate: String
    let dayIndex: Int
    let title: String
    let focus: String?
    let status: String
    var exercises: [TrainingPlanExercise]

    var completedSetsCount: Int {
        exercises.flatMap(\.sets).filter(\.isCompleted).count
    }

    var totalSetsCount: Int {
        exercises.flatMap(\.sets).count
    }

    var completedProgressUnits: Int {
        completedSetsCount + exercises.filter(\.isCardioCompleted).count
    }

    var totalProgressUnits: Int {
        totalSetsCount + exercises.filter { $0.itemType == .cardio }.count
    }

    /// 今天是否还有可以「开始训练」的力量组。专注模式只承载力量动作，
    /// 所以 dock 的开始 CTA 以此为准——有氧未完成不构成可开始的训练。
    var hasPendingStrengthSets: Bool {
        exercises.contains { exercise in
            exercise.itemType == .strength && exercise.sets.contains { !$0.isCompleted }
        }
    }

    /// 按 orderedExerciseIds 重排 exercises 并重写 orderIndex(0..<count)。
    /// orderedExerciseIds 必须是当前 exercises id 集合的一个排列，否则返回 nil。
    func reordered(byExerciseIds orderedExerciseIds: [String]) -> TrainingPlanDay? {
        guard orderedExerciseIds.count == exercises.count,
              Set(orderedExerciseIds) == Set(exercises.map(\.id)) else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        var newExercises: [TrainingPlanExercise] = []
        newExercises.reserveCapacity(orderedExerciseIds.count)
        for (index, id) in orderedExerciseIds.enumerated() {
            guard var exercise = byId[id] else { return nil }
            exercise.orderIndex = index
            newExercises.append(exercise)
        }
        var day = self
        day.exercises = newExercises
        return day
    }
}

nonisolated struct TrainingPlan: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let weekStartDate: String
    let goalSummary: String?
    let coachSummary: String
    var days: [TrainingPlanDay]
    /// Server-assigned optimistic-concurrency counter (Phase 3). Bumped by the
    /// `replan_plan_days` RPC on the server; the client only reads it, as the
    /// baseline for detecting a server-side replan before a push would clobber
    /// it (see CloudSyncCoordinator's revision guard). Defaults to 0 for plans
    /// created locally or loaded from a pre-Phase-3 cache.
    var revision: Int = 0

    var completedSetsCount: Int {
        days.reduce(0) { $0 + $1.completedSetsCount }
    }

    var totalSetsCount: Int {
        days.reduce(0) { $0 + $1.totalSetsCount }
    }

    var completedProgressUnits: Int {
        days.reduce(0) { $0 + $1.completedProgressUnits }
    }

    var totalProgressUnits: Int {
        days.reduce(0) { $0 + $1.totalProgressUnits }
    }
}

// `nonisolated` has to be repeated here: the keyword on the `TrainingPlan`
// declaration covers that declaration's own body, not a separate extension, so
// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` this `init(from:)` would
// default to `@MainActor` and make the `Decodable` conformance cross actors
// (an error in the Swift 6 language mode). Decoding runs on whatever thread the
// cache read or sync pull is on, so main-actor isolation would be wrong anyway.
nonisolated extension TrainingPlan {
    // Custom decode (in an extension, so the memberwise initializer is still
    // synthesized for the many call sites that build a plan directly) tolerates
    // a missing `revision` key in older on-disk caches. Encode stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case id, weekStartDate, goalSummary, coachSummary, days, revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        weekStartDate = try container.decode(String.self, forKey: .weekStartDate)
        goalSummary = try container.decodeIfPresent(String.self, forKey: .goalSummary)
        coachSummary = try container.decode(String.self, forKey: .coachSummary)
        days = try container.decode([TrainingPlanDay].self, forKey: .days)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }
}
