import Foundation

struct CompletedDaySummary: Equatable {
    let date: Date
    let strengthExerciseCount: Int
    let strengthSetCount: Int
    let cardioRecordCount: Int
    let totalDurationMinutes: Int
    let totalDistanceKm: Double

    var hasCompletedRecords: Bool {
        strengthExerciseCount > 0 || cardioRecordCount > 0
    }
}

struct CompletedStrengthExerciseViewData: Identifiable, Equatable {
    let id: String
    let name: String
    let completedSetCount: Int
    let sets: [CompletedStrengthSetViewData]
}

struct CompletedStrengthSetViewData: Identifiable, Equatable {
    enum LoadDisplay: Equatable {
        case weighted(Double, WeightUnit)
        case bodyweight
        case bodyweightWithAdded(Double, WeightUnit)
        case unrecordedWeight
    }

    let id: String
    let setIndex: Int
    let loadDisplay: LoadDisplay
    let reps: Int
    let rpe: Double?
}

struct CompletedCardioRecordViewData: Identifiable, Equatable {
    let id: String
    let activityType: CardioActivityType
    let source: RunningWorkoutSource
    let durationMinutes: Int
    let distanceKm: Double?
    let rpe: Double?
    let createdAt: Date

    var title: String {
        switch activityType {
        case .running: return String(localized: "cardio.activity.running")
        case .cycling: return String(localized: "cardio.activity.cycling")
        case .elliptical: return String(localized: "cardio.activity.elliptical")
        case .stairClimber: return String(localized: "cardio.activity.stair_climber")
        }
    }

    var paceText: String? {
        guard activityType == .running, let distanceKm, distanceKm > 0 else { return nil }
        let totalSeconds = Double(durationMinutes * 60)
        let secondsPerKm = totalSeconds / distanceKm
        guard secondsPerKm.isFinite else { return nil }
        let minutes = Int(secondsPerKm) / 60
        let seconds = Int(secondsPerKm) % 60
        return String(format: "%d:%02d /km", minutes, seconds)
    }
}

enum HistoryCompletedAggregator {
    static func daySummary(
        selectedDate: Date,
        sessions: [WorkoutSession],
        runningRecords: [RunningWorkoutRecord]
    ) -> CompletedDaySummary {
        CompletedDaySummary(
            date: selectedDate,
            strengthExerciseCount: strengthExercises(from: sessions).count,
            strengthSetCount: strengthExercises(from: sessions).reduce(0) { $0 + $1.sets.count },
            cardioRecordCount: runningRecords.count,
            totalDurationMinutes: sessions.reduce(0) { $0 + ($1.durationMinutes ?? 0) } +
                runningRecords.reduce(0) { $0 + $1.durationMinutes },
            totalDistanceKm: runningRecords.reduce(0) { $0 + ($1.distanceKm ?? 0) }
        )
    }

    static func strengthExercises(from sessions: [WorkoutSession]) -> [CompletedStrengthExerciseViewData] {
        sessions
            .flatMap(\.exercises)
            .map { exercise in
                let hasAnyExplicitWeight = exercise.sets.contains { $0.weight != nil }
                // Legacy sessions predate `exerciseLoadType`; fall back to the
                // old "any set here ever had a real weight" heuristic for them.
                let isBodyweightExercise = exercise.exerciseLoadType == .bodyweight
                    || (exercise.exerciseLoadType == nil && !hasAnyExplicitWeight)
                return CompletedStrengthExerciseViewData(
                    id: exercise.id,
                    name: exercise.name,
                    completedSetCount: exercise.sets.count,
                    sets: exercise.sets.map { set in
                        let loadDisplay: CompletedStrengthSetViewData.LoadDisplay
                        if isBodyweightExercise {
                            if let weight = set.weight, weight > 0 {
                                loadDisplay = .bodyweightWithAdded(weight, set.weightUnit)
                            } else {
                                loadDisplay = .bodyweight
                            }
                        } else if let weight = set.weight {
                            loadDisplay = .weighted(weight, set.weightUnit)
                        } else {
                            loadDisplay = .unrecordedWeight
                        }

                        return CompletedStrengthSetViewData(
                            id: set.id,
                            setIndex: set.setIndex,
                            loadDisplay: loadDisplay,
                            reps: set.reps,
                            rpe: set.rpe
                        )
                    }
                )
            }
    }

    /// Muscle groups hit by the day's strength work, dominant (most sets) first.
    /// Exercises that can't be resolved against the library are skipped.
    static func dominantMuscleGroups(
        sessions: [WorkoutSession],
        library: [ExerciseDefinition],
        limit: Int = 3
    ) -> [MuscleGroup] {
        guard !library.isEmpty else { return [] }

        var setCounts: [MuscleGroup: Int] = [:]
        for exercise in sessions.flatMap(\.exercises) {
            guard let definition = ExerciseLibraryEngine.resolveDefinition(
                name: exercise.name,
                exerciseId: exercise.exerciseId,
                in: library
            ) else { continue }
            setCounts[definition.muscleGroup, default: 0] += max(exercise.sets.count, 1)
        }

        let rank = { (group: MuscleGroup) in MuscleGroup.allCases.firstIndex(of: group) ?? 0 }
        return setCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return rank(lhs.key) < rank(rhs.key)
            }
            .prefix(limit)
            .map(\.key)
    }

    static func cardioRecords(from runningRecords: [RunningWorkoutRecord]) -> [CompletedCardioRecordViewData] {
        runningRecords.map { record in
            CompletedCardioRecordViewData(
                id: record.id,
                activityType: record.activityType,
                source: record.source,
                durationMinutes: record.durationMinutes,
                distanceKm: record.distanceKm,
                rpe: record.rpe,
                createdAt: record.createdAt
            )
        }
    }
}
