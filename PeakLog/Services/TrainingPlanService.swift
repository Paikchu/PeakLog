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
    func deletePlannedExercise(planExerciseId: String) async throws
    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay
    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay
    /// 把动作安排到指定日期（"yyyy-MM-dd"）；用于统一训练页的未来日编辑。
    func addPlannedExercises(_ drafts: [PlanExerciseDraft], planDate: String) async throws -> TrainingPlanDay
    /// 重排指定日期的计划日；用于统一训练页的未来日编辑。
    func reorderPlannedExercises(orderedExerciseIds: [String], planDate: String) async throws -> TrainingPlanDay
    func recordDaySignal(_ signal: ReplanSignal) async throws
    func completePlannedCardio(planExerciseId: String, metrics: CardioMetrics) async throws -> CardioWorkoutRecord
}

extension TrainingPlanServiceProtocol {
    // Default no-op: only the local (real) service records the signal. Mocks
    // and empty services inherit this and need no change.
    func recordDaySignal(_ signal: ReplanSignal) async throws {}
    func completePlannedCardio(planExerciseId: String, metrics: CardioMetrics) async throws -> CardioWorkoutRecord {
        throw LocalAppDatabaseError.planExerciseNotFound
    }
    // 带 planDate 的变体默认回落到"今天"版本：既有 mock/测试替身不感知
    // 日期参数也能满足协议；真实服务（Local/Empty）各自覆写为按日期写入。
    func addPlannedExercises(_ drafts: [PlanExerciseDraft], planDate: String) async throws -> TrainingPlanDay {
        try await addPlannedExercises(drafts)
    }
    func reorderPlannedExercises(orderedExerciseIds: [String], planDate: String) async throws -> TrainingPlanDay {
        try await reorderPlannedExercises(orderedExerciseIds: orderedExerciseIds)
    }
}

final class LocalTrainingPlanService: TrainingPlanServiceProtocol {
    private let database: LocalAppDatabase

    init(database: LocalAppDatabase) {
        self.database = database
    }

    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? {
        await database.activePlan()
    }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        await database.todayPlan()
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet {
        try await database.completePlannedSet(
            planSetId: planSetId,
            actualWeight: actualWeight,
            actualWeightUnit: actualWeightUnit,
            actualReps: actualReps
        )
    }

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        try await database.updatePlannedSet(
            planSetId: planSetId,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps
        )
    }

    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        try await database.addPlannedSet(
            planExerciseId: planExerciseId,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps
        )
    }

    func deletePlannedSet(planSetId: String) async throws {
        try await database.deletePlannedSet(planSetId: planSetId)
    }

    func deletePlannedExercise(planExerciseId: String) async throws {
        try await database.deletePlannedExercise(planExerciseId: planExerciseId)
    }

    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay {
        try await database.addPlannedExercises(drafts)
    }

    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay {
        try await database.reorderPlannedExercises(orderedExerciseIds: orderedExerciseIds)
    }

    func addPlannedExercises(_ drafts: [PlanExerciseDraft], planDate: String) async throws -> TrainingPlanDay {
        try await database.addPlannedExercises(drafts, planDate: planDate)
    }

    func reorderPlannedExercises(orderedExerciseIds: [String], planDate: String) async throws -> TrainingPlanDay {
        try await database.reorderPlannedExercises(orderedExerciseIds: orderedExerciseIds, planDate: planDate)
    }

    func recordDaySignal(_ signal: ReplanSignal) async throws {
        try await database.recordDaySignal(signal)
    }

    func completePlannedCardio(planExerciseId: String, metrics: CardioMetrics) async throws -> CardioWorkoutRecord {
        try await database.completePlannedCardio(planExerciseId: planExerciseId, metrics: metrics)
    }
}
