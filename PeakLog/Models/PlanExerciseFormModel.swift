import Foundation

// MARK: - Plan Exercise Draft
// Persistable payload for manually adding exercises to today's plan.
// Shares DailyRecordExerciseInput as the editable form state so the
// add-to-plan sheet and the manual-record sheet stay in sync.

struct PlanExerciseDraft: Equatable, Sendable {
    struct SetDraft: Equatable, Sendable {
        var targetWeight: Double?
        var targetWeightUnit: WeightUnit
        var targetReps: Int
    }

    var exerciseName: String
    var exerciseId: String? = nil
    var isBodyweight: Bool
    var sets: [SetDraft]
    var itemType: PlanItemType = .strength
    var cardioActivityType: CardioActivityType? = nil
    var targetDurationMinutes: Int? = nil
    var targetDistanceKm: Double? = nil
    var targetRPE: Double? = nil

    static func cardio(
        activityType: CardioActivityType,
        targetDurationMinutes: Int,
        targetDistanceKm: Double?,
        targetRPE: Double?
    ) throws -> PlanExerciseDraft {
        let metrics = try CardioMetrics(
            activityType: activityType,
            durationMinutes: targetDurationMinutes,
            distanceKm: targetDistanceKm,
            rpe: targetRPE
        )
        return PlanExerciseDraft(
            exerciseName: activityType.localizedTitle,
            isBodyweight: false,
            sets: [],
            itemType: .cardio,
            cardioActivityType: metrics.activityType,
            targetDurationMinutes: metrics.durationMinutes,
            targetDistanceKm: metrics.distanceKm,
            targetRPE: metrics.rpe
        )
    }
}

enum PlanExerciseDraftBuilder {
    /// Maps the editable form state to plan-exercise drafts.
    /// Returns nil when any exercise is incomplete, which keeps the save button disabled.
    static func drafts(exercises: [DailyRecordExerciseInput]) -> [PlanExerciseDraft]? {
        guard !exercises.isEmpty else { return nil }

        var result: [PlanExerciseDraft] = []
        for exercise in exercises {
            let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !exercise.sets.isEmpty else { return nil }

            var setDrafts: [PlanExerciseDraft.SetDraft] = []
            for set in exercise.sets {
                guard set.reps > 0 else { return nil }
                if exercise.isBodyweight {
                    // nil means pure bodyweight; a non-negative value is added weight on top of it.
                    guard (set.weight ?? 0) >= 0 else { return nil }
                    setDrafts.append(.init(targetWeight: set.weight, targetWeightUnit: .kg, targetReps: set.reps))
                } else {
                    guard let weight = set.weight, weight > 0 else { return nil }
                    setDrafts.append(.init(targetWeight: weight, targetWeightUnit: .kg, targetReps: set.reps))
                }
            }
            result.append(PlanExerciseDraft(
                exerciseName: name,
                exerciseId: exercise.sourceExerciseId,
                isBodyweight: exercise.isBodyweight,
                sets: setDrafts
            ))
        }
        return result
    }
}
