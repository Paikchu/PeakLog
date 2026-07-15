import Foundation

// MARK: - Daily Record Form Inputs
// Editable state backing DailyRecordSheet. Kept UIKit-free so the
// draft-building rules can be exercised by tests/daily_record_multi_exercise_draft_test.swift.

struct DailyRecordSetInput: Identifiable, Equatable, Sendable {
    let id: UUID
    var weight: Double?
    var reps: Int

    init(id: UUID = UUID(), weight: Double? = nil, reps: Int = 8) {
        self.id = id
        self.weight = weight
        self.reps = reps
    }
}

struct DailyRecordExerciseInput: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// Library slug of the picked exercise; nil for legacy free-text entries.
    var sourceExerciseId: String?
    var isBodyweight: Bool
    var sets: [DailyRecordSetInput]

    init(
        id: UUID = UUID(),
        name: String = "",
        sourceExerciseId: String? = nil,
        isBodyweight: Bool = false,
        sets: [DailyRecordSetInput] = [DailyRecordSetInput()]
    ) {
        self.id = id
        self.name = name
        self.sourceExerciseId = sourceExerciseId
        self.isBodyweight = isBodyweight
        self.sets = sets
    }

    init(definition: ExerciseDefinition, language: AppLanguage) {
        self.init(
            name: definition.displayName(for: language),
            sourceExerciseId: definition.id,
            isBodyweight: definition.loadType == .bodyweight
        )
    }

    mutating func appendSetCopyingLast() {
        let template = sets.last
        sets.append(DailyRecordSetInput(weight: template?.weight, reps: template?.reps ?? 8))
    }

    mutating func removeLastSet() {
        guard sets.count > 1 else { return }
        sets.removeLast()
    }
}

// MARK: - Draft Builder

enum DailyRecordDraftBuilder {
    /// Maps the editable form state to a persistable draft.
    /// Returns nil when any exercise is incomplete, which keeps the save button disabled.
    static func strengthDraft(
        title: String,
        workoutDate: Date,
        exercises: [DailyRecordExerciseInput]
    ) -> StrengthSessionDraft? {
        guard !exercises.isEmpty else { return nil }

        var exerciseDrafts: [StrengthSessionDraft.ExerciseDraft] = []
        for exercise in exercises {
            let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !exercise.sets.isEmpty else { return nil }

            var setDrafts: [StrengthSessionDraft.ExerciseDraft.SetDraft] = []
            for set in exercise.sets {
                guard set.reps > 0 else { return nil }
                if exercise.isBodyweight {
                    // nil means pure bodyweight; a non-negative value is added weight on top of it.
                    guard (set.weight ?? 0) >= 0 else { return nil }
                    setDrafts.append(.init(weight: set.weight, weightUnit: .kg, reps: set.reps, rpe: nil))
                } else {
                    guard let weight = set.weight, weight > 0 else { return nil }
                    setDrafts.append(.init(weight: weight, weightUnit: .kg, reps: set.reps, rpe: nil))
                }
            }
            exerciseDrafts.append(.init(
                name: name,
                exerciseId: exercise.sourceExerciseId,
                exerciseLoadType: exercise.isBodyweight ? .bodyweight : .weighted,
                sets: setDrafts
            ))
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return StrengthSessionDraft(
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            workoutDate: workoutDate,
            exercises: exerciseDrafts
        )
    }
}
