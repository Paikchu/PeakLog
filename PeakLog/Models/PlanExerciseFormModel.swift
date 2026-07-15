import Foundation

// MARK: - Plan Exercise Draft
// Persistable payload for manually adding exercises to today's plan.
// Shares DailyRecordExerciseInput as the editable form state so the
// add-to-plan sheet and the manual-record sheet stay in sync.

enum ExercisePickerItem: Identifiable, Equatable, Sendable {
    case strength(ExerciseDefinition)
    case cardio(CardioActivityType)

    var id: String {
        switch self {
        case .strength(let definition): "strength:\(definition.id)"
        case .cardio(let activity): "cardio:\(activity.rawValue)"
        }
    }

    func displayName(for language: AppLanguage) -> String {
        switch self {
        case .strength(let definition): definition.displayName(for: language)
        case .cardio(let activity): activity.localizedTitle
        }
    }
}

struct CardioPlanExerciseInput: Identifiable, Equatable, Sendable {
    let id: UUID
    var activityType: CardioActivityType
    var durationText: String
    var distanceText: String

    init(
        id: UUID = UUID(),
        activityType: CardioActivityType,
        durationText: String = "30",
        distanceText: String = ""
    ) {
        self.id = id
        self.activityType = activityType
        self.durationText = durationText
        self.distanceText = distanceText
    }

    func draft() -> PlanExerciseDraft? {
        let trimmedDuration = durationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDistance = distanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = Int(trimmedDuration) else { return nil }
        let distance = activityType.supportsDistance && !trimmedDistance.isEmpty
            ? Double(trimmedDistance) : nil
        guard !activityType.supportsDistance || trimmedDistance.isEmpty || distance != nil else { return nil }
        return try? PlanExerciseDraft.cardio(
            activityType: activityType,
            targetDurationMinutes: duration,
            targetDistanceKm: distance
        )
    }
}

enum PlanExerciseFormItem: Identifiable, Equatable, Sendable {
    case strength(DailyRecordExerciseInput)
    case cardio(CardioPlanExerciseInput)

    var id: UUID {
        switch self {
        case .strength(let input): input.id
        case .cardio(let input): input.id
        }
    }

    var pickerItemID: String {
        switch self {
        case .strength(let input):
            return "strength:\(input.sourceExerciseId ?? input.id.uuidString)"
        case .cardio(let input):
            return "cardio:\(input.activityType.rawValue)"
        }
    }
}

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
        targetDistanceKm: Double?
    ) throws -> PlanExerciseDraft {
        let metrics = try CardioMetrics(
            activityType: activityType,
            durationMinutes: targetDurationMinutes,
            distanceKm: targetDistanceKm,
            rpe: nil
        )
        return PlanExerciseDraft(
            exerciseName: activityType.localizedTitle,
            isBodyweight: false,
            sets: [],
            itemType: .cardio,
            cardioActivityType: metrics.activityType,
            targetDurationMinutes: metrics.durationMinutes,
            targetDistanceKm: metrics.distanceKm,
            targetRPE: nil
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
            guard let draft = strengthDraft(from: exercise) else { return nil }
            result.append(draft)
        }
        return result
    }

    static func drafts(items: [PlanExerciseFormItem]) -> [PlanExerciseDraft]? {
        guard !items.isEmpty else { return nil }

        var result: [PlanExerciseDraft] = []
        var seenPickerItemIDs: Set<String> = []
        for item in items {
            guard seenPickerItemIDs.insert(item.pickerItemID).inserted else { return nil }

            switch item {
            case .strength(let exercise):
                guard let draft = strengthDraft(from: exercise) else { return nil }
                result.append(draft)
            case .cardio(let input):
                guard let draft = input.draft() else { return nil }
                result.append(draft)
            }
        }
        return result
    }

    private static func strengthDraft(from exercise: DailyRecordExerciseInput) -> PlanExerciseDraft? {
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
        return PlanExerciseDraft(
            exerciseName: name,
            exerciseId: exercise.sourceExerciseId,
            isBodyweight: exercise.isBodyweight,
            sets: setDrafts
        )
    }

    /// Appends a cardio draft without discarding strength cards already configured in the sheet.
    /// An incomplete strength card blocks the combined submission.
    static func drafts(
        exercises: [DailyRecordExerciseInput],
        appending cardioDraft: PlanExerciseDraft
    ) -> [PlanExerciseDraft]? {
        guard !exercises.isEmpty else { return [cardioDraft] }
        guard let strengthDrafts = drafts(exercises: exercises) else { return nil }
        return strengthDrafts + [cardioDraft]
    }
}
