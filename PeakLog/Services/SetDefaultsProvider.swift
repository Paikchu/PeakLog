import Foundation

// MARK: - Set Defaults
// Suggests a starting weight/reps when the user opens a set to edit it, or
// when a new set is appended. `RuleBasedSetDefaultsProvider` answers purely
// from logged history today; the protocol is history-in/suggestion-out so a
// future LLM-backed implementation (e.g. one that also weighs RPE trends or
// planned progression) can be swapped in at the `AppServices` wiring point
// without touching any call site.

nonisolated struct SetDefaultsContext: Sendable {
    /// Stable library slug when known; falls back to name matching otherwise.
    let exerciseId: String?
    let exerciseName: String
    /// 1-based position of the set being filled within its exercise.
    let setIndex: Int
    /// Weight/reps already present one row above, in the *same* session or
    /// plan day — the cheapest and most relevant signal when it exists, so
    /// callers pass it in rather than have every provider re-derive it.
    let precedingSetInSameExercise: SetDefaultsSuggestion?

    init(
        exerciseId: String?,
        exerciseName: String,
        setIndex: Int,
        precedingSetInSameExercise: SetDefaultsSuggestion? = nil
    ) {
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.setIndex = setIndex
        self.precedingSetInSameExercise = precedingSetInSameExercise
    }
}

nonisolated struct SetDefaultsSuggestion: Sendable, Equatable {
    var weight: Double?
    var weightUnit: WeightUnit
    var reps: Int?
}

protocol SetDefaultsProviding: Sendable {
    func suggestDefaults(for context: SetDefaultsContext) async -> SetDefaultsSuggestion?
    /// The unit a brand-new set should be created in when there is no prior
    /// weight to copy the unit from at all.
    func preferredWeightUnit() async -> WeightUnit
}

struct RuleBasedSetDefaultsProvider: SetDefaultsProviding {
    private let exerciseLibraryService: ExerciseLibraryServiceProtocol
    private let profileService: ProfileServiceProtocol

    init(exerciseLibraryService: ExerciseLibraryServiceProtocol, profileService: ProfileServiceProtocol) {
        self.exerciseLibraryService = exerciseLibraryService
        self.profileService = profileService
    }

    func suggestDefaults(for context: SetDefaultsContext) async -> SetDefaultsSuggestion? {
        if let preceding = context.precedingSetInSameExercise {
            return preceding
        }

        guard let sets = await exerciseLibraryService.fetchLastPerformedSets(
            exerciseId: context.exerciseId,
            exerciseName: context.exerciseName
        ), !sets.isEmpty else {
            return nil
        }

        // Same set number as last time (e.g. set 3 tends to be lighter than
        // set 1), falling back to the first set for a number that didn't exist.
        guard let matched = sets.first(where: { $0.setIndex == context.setIndex }) ?? sets.first else {
            return nil
        }

        return SetDefaultsSuggestion(weight: matched.weight, weightUnit: matched.weightUnit, reps: matched.reps)
    }

    func preferredWeightUnit() async -> WeightUnit {
        (try? await profileService.fetchProfile().preferences.weightUnit) ?? .kg
    }
}
