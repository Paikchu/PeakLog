import Foundation

struct TrainingPlanSet: Identifiable, Codable, Equatable {
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

struct TrainingPlanExercise: Identifiable, Codable, Equatable {
    let id: String
    let orderIndex: Int
    let exerciseName: String
    let progressionMode: String
    let notes: String?
    var previousPerformanceSummary: String?
    var aiSuggestion: String?
    var sets: [TrainingPlanSet]
}

struct TrainingPlanDay: Identifiable, Codable, Equatable {
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
}

struct TrainingPlan: Identifiable, Codable, Equatable {
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

extension TrainingPlanSet {
    init(block: PlanSetBlock) {
        let formatter = ISO8601DateFormatter()
        self.init(
            id: block.planSetId,
            setIndex: block.setIndex,
            targetWeight: block.targetWeight,
            targetWeightUnit: WeightUnit(rawValue: block.targetWeightUnit) ?? .kg,
            targetReps: block.targetReps,
            completedAt: block.completedAt.flatMap { formatter.date(from: $0) },
            linkedExerciseSetId: block.linkedExerciseSetId
        )
    }
}

extension TrainingPlanExercise {
    init(block: PlanExerciseBlock) {
        self.init(
            id: block.planExerciseId,
            orderIndex: block.orderIndex,
            exerciseName: block.exerciseName,
            progressionMode: block.progressionMode,
            notes: block.notes,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: block.sets.map(TrainingPlanSet.init(block:))
        )
    }
}

extension TrainingPlanDay {
    init(block: PlanDayBlock) {
        self.init(
            id: block.planDayId,
            planDate: block.planDate,
            dayIndex: block.dayIndex,
            title: block.title,
            focus: block.focus,
            status: block.status,
            exercises: block.exercises.map(TrainingPlanExercise.init(block:))
        )
    }
}

extension TrainingPlan {
    init(block: WeeklyPlanBlock) {
        self.init(
            id: block.planId,
            weekStartDate: block.weekStartDate,
            goalSummary: block.goalSummary,
            coachSummary: block.coachSummary,
            days: block.days.map(TrainingPlanDay.init(block:))
        )
    }
}
