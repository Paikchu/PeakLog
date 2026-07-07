import Foundation

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
        sets: [TrainingPlanSet]
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

    var completedSetsCount: Int {
        days.reduce(0) { $0 + $1.completedSetsCount }
    }

    var totalSetsCount: Int {
        days.reduce(0) { $0 + $1.totalSetsCount }
    }
}
