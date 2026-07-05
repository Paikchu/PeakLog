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
    var isBodyweight: Bool
    var sets: [SetDraft]
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
                    setDrafts.append(.init(targetWeight: nil, targetWeightUnit: .kg, targetReps: set.reps))
                } else {
                    guard let weight = set.weight, weight > 0 else { return nil }
                    setDrafts.append(.init(targetWeight: weight, targetWeightUnit: .kg, targetReps: set.reps))
                }
            }
            result.append(PlanExerciseDraft(exerciseName: name, isBodyweight: exercise.isBodyweight, sets: setDrafts))
        }
        return result
    }
}
