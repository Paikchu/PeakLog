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
