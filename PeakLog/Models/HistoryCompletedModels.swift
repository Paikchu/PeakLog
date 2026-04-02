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
    let title: String
    let source: RunningWorkoutSource
    let durationMinutes: Int
    let distanceKm: Double
    let createdAt: Date

    var paceText: String? {
        guard distanceKm > 0 else { return nil }
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
            totalDistanceKm: runningRecords.reduce(0) { $0 + $1.distanceKm }
        )
    }

    static func strengthExercises(from sessions: [WorkoutSession]) -> [CompletedStrengthExerciseViewData] {
        sessions
            .flatMap(\.exercises)
            .map { exercise in
                let hasAnyExplicitWeight = exercise.sets.contains { $0.weight != nil }
                return CompletedStrengthExerciseViewData(
                    id: exercise.id,
                    name: exercise.name,
                    completedSetCount: exercise.sets.count,
                    sets: exercise.sets.map { set in
                        let loadDisplay: CompletedStrengthSetViewData.LoadDisplay
                        if let weight = set.weight {
                            loadDisplay = .weighted(weight, set.weightUnit)
                        } else if hasAnyExplicitWeight {
                            loadDisplay = .unrecordedWeight
                        } else {
                            loadDisplay = .bodyweight
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

    static func cardioRecords(from runningRecords: [RunningWorkoutRecord]) -> [CompletedCardioRecordViewData] {
        runningRecords.map { record in
            CompletedCardioRecordViewData(
                id: record.id,
                title: "跑步",
                source: record.source,
                durationMinutes: record.durationMinutes,
                distanceKm: record.distanceKm,
                createdAt: record.createdAt
            )
        }
    }
}
