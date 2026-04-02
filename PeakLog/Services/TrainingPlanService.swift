import Foundation

protocol TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan?
    func fetchTodayPlan() async throws -> TrainingPlanDay?
    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet
    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet
    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet
    func deletePlannedSet(planSetId: String) async throws
}

final class EmptyTrainingPlanService: TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }
    func fetchTodayPlan() async throws -> TrainingPlanDay? { nil }
    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: planSetId,
            setIndex: 1,
            targetWeight: actualWeight,
            targetWeightUnit: actualWeightUnit,
            targetReps: actualReps,
            completedAt: Date(),
            linkedExerciseSetId: nil
        )
    }

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: planSetId,
            setIndex: 1,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: "\(planExerciseId)-new-set",
            setIndex: 1,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}
}

final class MockTrainingPlanService: TrainingPlanServiceProtocol {
    private let samplePlan: TrainingPlan

    init() {
        samplePlan = TrainingPlan(
            id: "plan-1",
            weekStartDate: "2026-03-23",
            goalSummary: "Build muscle with extra focus on upper body pressing strength.",
            coachSummary: "4 training days this week. Push today, pull tomorrow.",
            days: [
                TrainingPlanDay(
                    id: "day-1",
                    planDate: "2026-03-24",
                    dayIndex: 1,
                    title: "Push Strength",
                    focus: "Chest, shoulders, triceps",
                    status: "planned",
                    exercises: [
                        TrainingPlanExercise(
                            id: "exercise-1",
                            orderIndex: 0,
                            exerciseName: "Bench Press",
                            exerciseLoadType: .weighted,
                            progressionMode: "weight_first",
                            notes: "Complete all sets before increasing load next week.",
                            previousPerformanceSummary: nil,
                            aiSuggestion: nil,
                            sets: [
                                TrainingPlanSet(
                                    id: "set-1",
                                    setIndex: 1,
                                    targetWeight: 40,
                                    targetWeightUnit: .kg,
                                    targetReps: 8,
                                    completedAt: nil,
                                    linkedExerciseSetId: nil
                                ),
                                TrainingPlanSet(
                                    id: "set-2",
                                    setIndex: 2,
                                    targetWeight: 40,
                                    targetWeightUnit: .kg,
                                    targetReps: 8,
                                    completedAt: nil,
                                    linkedExerciseSetId: nil
                                ),
                            ]
                        ),
                    ]
                )
            ]
        )
    }

    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? {
        samplePlan
    }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        samplePlan.days.first
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: planSetId,
            setIndex: 1,
            targetWeight: actualWeight,
            targetWeightUnit: actualWeightUnit,
            targetReps: actualReps,
            completedAt: Date(),
            linkedExerciseSetId: "exercise-set-\(planSetId)"
        )
    }

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: planSetId,
            setIndex: 1,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: UUID().uuidString,
            setIndex: 99,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}
}
