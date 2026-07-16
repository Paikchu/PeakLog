import Foundation
import Combine

/// 未来日计划编辑的写路径。改目标/加减组/删动作走按 id 的既有接口
/// （本地库按 id 全周查找，天然支持任意计划日）；加动作/重排走带
/// planDate 的新接口。每次写操作成功后通过 `onPlanChanged` 让宿主
/// （HistoryViewModel）重拉激活计划——未来日没有 live session 要保护，
/// 全量刷新比乐观补丁更不易出错。
///
/// 独立于 TodayWorkoutViewModel 与 HistoryViewModel：前者绑死"今天 +
/// 训练 session"，后者被多个 swiftc 契约脚本按源码编译，塞入服务写
/// 调用会扩大它们的编译面。Phase B 统一 ViewModel 时一并收编。
@MainActor
final class FutureDayPlanEditorViewModel: ObservableObject {
    @Published var errorMessage: String?

    private let trainingPlanService: TrainingPlanServiceProtocol
    private let dateFormatter = WorkoutDateFormatter()

    /// 写操作成功后调用；宿主用它刷新 activePlan / selectedPlanDay / 周条圆点。
    var onPlanChanged: (() async -> Void)?

    init(trainingPlanService: TrainingPlanServiceProtocol) {
        self.trainingPlanService = trainingPlanService
    }

    #if !TESTING
    convenience init() {
        self.init(trainingPlanService: AppServices.trainingPlanService)
    }
    #endif

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async {
        await perform {
            _ = try await self.trainingPlanService.updatePlannedSet(
                planSetId: planSetId,
                targetWeight: targetWeight,
                targetWeightUnit: targetWeightUnit,
                targetReps: targetReps
            )
        }
    }

    /// 与今日页一致：以最后一组为模板，无组时退回 10 次的空目标。
    func addSet(to exercise: TrainingPlanExercise) async {
        let template = exercise.sets.last
        await perform {
            _ = try await self.trainingPlanService.addPlannedSet(
                planExerciseId: exercise.id,
                targetWeight: template?.targetWeight,
                targetWeightUnit: template?.targetWeightUnit ?? .kg,
                targetReps: template?.targetReps ?? 10
            )
        }
    }

    func deleteLastSet(of exercise: TrainingPlanExercise) async {
        guard let lastSetId = exercise.sets.last?.id else { return }
        await perform {
            try await self.trainingPlanService.deletePlannedSet(planSetId: lastSetId)
        }
    }

    func deleteExercise(planExerciseId: String) async {
        await perform {
            try await self.trainingPlanService.deletePlannedExercise(planExerciseId: planExerciseId)
        }
    }

    /// 把动作安排到指定未来日（休息日由此升级为训练日）。
    /// 抛错让 AddPlanExerciseSheet 自己展示失败态，成功才刷新。
    func addExercises(_ drafts: [PlanExerciseDraft], to date: Date) async throws {
        _ = try await trainingPlanService.addPlannedExercises(
            drafts,
            planDate: dateFormatter.string(from: date)
        )
        await onPlanChanged?()
    }

    func reorderExercises(orderedExerciseIds: [String], on date: Date) async {
        await perform {
            _ = try await self.trainingPlanService.reorderPlannedExercises(
                orderedExerciseIds: orderedExerciseIds,
                planDate: self.dateFormatter.string(from: date)
            )
        }
    }

    private func perform(_ mutation: () async throws -> Void) async {
        do {
            try await mutation()
            await onPlanChanged?()
        } catch {
            errorMessage = error.localizedDescription
            // 失败也刷新一次，把界面拉回落库的真实状态。
            await onPlanChanged?()
        }
    }
}
