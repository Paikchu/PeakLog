import Foundation

/// 「结束并保存」后展示的训练小结：时长、总容量、完成组数、逐动作最好成绩
/// 与是否刷新个人纪录。由 `PlanLiveWorkoutSession` 在 confirm 成功后一次性
/// 计算生成，纯值类型，不再回查数据库。
nonisolated struct TrainingSessionSummary: Identifiable, Equatable, Sendable {
    nonisolated struct ExerciseSummary: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let completedSets: Int
        let totalSets: Int
        /// 已完成组里最重一组的展示文本（保留记录时的单位），如 "60 kg × 8"；
        /// 纯自重/无重量动作为 nil。
        let bestSetDisplay: String?
        /// 该动作已完成组的最大重量（kg 归一），用于 PR 判定与测试断言。
        let bestWeightKg: Double?
        let isNewRecord: Bool
        let wasSkipped: Bool
    }

    let id: String
    let title: String
    /// 训练时长（秒）。旧版本持久化的 session 没有 `startedAt`，恢复后结束
    /// 时长未知，界面上隐藏该格。
    let durationSeconds: Int?
    let completedSets: Int
    let totalSets: Int
    let totalVolumeKg: Double
    let preferredUnit: WeightUnit
    let exercises: [ExerciseSummary]

    var newRecordCount: Int {
        exercises.count(where: \.isNewRecord)
    }

    var newRecordExercises: [ExerciseSummary] {
        exercises.filter(\.isNewRecord)
    }

    /// 从已结束的 session 计算小结。一组都没完成时返回 nil（没有可总结的内容，
    /// 这种收尾更接近取消而不是完成）。
    ///
    /// - Parameter priorPRs: 按 `ExercisePR.normalizedName` 索引的历史 PR 基线，
    ///   必须取自本次训练落库**之前**；为 nil 表示基线不可用，跳过 PR 判定。
    static func make(
        session: PlanLiveWorkoutSession,
        priorPRs: [String: ExercisePR]?,
        preferredUnit: WeightUnit,
        endedAt: Date
    ) -> TrainingSessionSummary? {
        guard session.completedSetsCount > 0 else { return nil }

        var totalVolumeKg = 0.0
        let exerciseSummaries = session.exercises.map { exercise -> ExerciseSummary in
            let completedSets = exercise.sets.filter { session.completedSetIds.contains($0.id) }

            var bestSet: PlanLiveWorkoutSet?
            for set in completedSets {
                guard let weight = set.targetWeight else { continue }
                totalVolumeKg += weight * set.targetWeightUnit.toKilogramsFactor * Double(set.targetReps)
                if let currentBest = bestSet, let bestWeight = currentBest.targetWeight,
                   bestWeight * currentBest.targetWeightUnit.toKilogramsFactor
                       >= weight * set.targetWeightUnit.toKilogramsFactor {
                    continue
                }
                bestSet = set
            }

            let bestWeightKg = bestSet.flatMap { set in
                set.targetWeight.map { $0 * set.targetWeightUnit.toKilogramsFactor }
            }

            // 与 `makeExercisePRs` 用同一套名字归一规则，否则同一动作对不上基线。
            let normalizedName = exercise.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let isNewRecord: Bool
            if let priorPRs, let bestWeightKg {
                isNewRecord = bestWeightKg > (priorPRs[normalizedName]?.maxWeightKg ?? 0)
            } else {
                isNewRecord = false
            }

            return ExerciseSummary(
                id: exercise.id,
                name: exercise.name,
                completedSets: completedSets.count,
                totalSets: exercise.sets.count,
                bestSetDisplay: bestSet.flatMap { set in
                    set.targetWeight.map { weight in
                        "\(formatSummaryWeight(weight)) \(set.targetWeightUnit.display) × \(set.targetReps)"
                    }
                },
                bestWeightKg: bestWeightKg,
                isNewRecord: isNewRecord,
                wasSkipped: session.skippedExerciseIds.contains(exercise.id)
                    && completedSets.count < exercise.sets.count
            )
        }

        let durationSeconds = session.startedAt.map {
            max(Int(endedAt.timeIntervalSince($0).rounded()), 0)
        }

        return TrainingSessionSummary(
            id: session.id,
            title: session.title,
            durationSeconds: durationSeconds,
            completedSets: session.completedSetsCount,
            totalSets: session.totalSetsCount,
            totalVolumeKg: totalVolumeKg,
            preferredUnit: preferredUnit,
            exercises: exerciseSummaries
        )
    }

    // MARK: - Display

    /// "42:07"（不足一小时）或 "1:02:07"。
    var durationDisplay: String? {
        durationSeconds.map { total in
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let seconds = total % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            }
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    /// 与 Profile 的 `volumeDisplay` 同一套规则：按偏好单位展示，
    /// 大数值折成 "t" / "k lbs"。
    var volumeDisplay: String {
        switch preferredUnit {
        case .kg:
            if totalVolumeKg >= 1000 {
                return String(format: "%.1ft", totalVolumeKg / 1000)
            }
            return String(format: "%.0fkg", totalVolumeKg)
        case .lbs:
            let lbs = totalVolumeKg / WeightUnit.lbs.toKilogramsFactor
            if lbs >= 1000 {
                return String(format: "%.1fk lbs", lbs / 1000)
            }
            return String(format: "%.0flbs", lbs)
        }
    }
}

nonisolated private func formatSummaryWeight(_ weight: Double) -> String {
    weight.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(weight)) : String(format: "%.1f", weight)
}
