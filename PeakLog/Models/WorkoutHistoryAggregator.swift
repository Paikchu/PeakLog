import Foundation

enum WorkoutHistoryAggregator {
    static func mergeSessionsForHistory(_ sessions: [WorkoutSession]) -> [WorkoutSession] {
        guard !sessions.isEmpty else { return [] }

        let orderedSessions = sessions.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id < $1.id
        }

        let groupedExercises = mergeExercises(from: orderedSessions)
        let combinedDuration = orderedSessions.reduce(0) { partial, session in
            partial + (session.durationMinutes ?? 0)
        }

        let firstSession = orderedSessions[0]
        let mergedSession = WorkoutSession(
            id: "history-\(historyDayKey(for: firstSession.date))",
            userId: firstSession.userId,
            date: firstSession.date,
            durationMinutes: combinedDuration > 0 ? combinedDuration : nil,
            label: nil,
            exercises: groupedExercises,
            createdAt: firstSession.createdAt,
            updatedAt: orderedSessions.map(\.updatedAt).max() ?? firstSession.updatedAt
        )

        return [mergedSession]
    }

    private static func mergeExercises(from sessions: [WorkoutSession]) -> [Exercise] {
        var grouped: [String: Exercise] = [:]
        var order: [String] = []

        for session in sessions {
            for exercise in session.exercises {
                let key = normalizedName(for: exercise.name)
                if grouped[key] == nil {
                    grouped[key] = Exercise(id: exercise.id, name: exercise.name, sets: [])
                    order.append(key)
                }

                let nextSets = exercise.sets
                    .sorted { lhs, rhs in
                        if lhs.setIndex != rhs.setIndex {
                            return lhs.setIndex < rhs.setIndex
                        }
                        return lhs.id < rhs.id
                    }

                grouped[key]?.sets.append(contentsOf: nextSets)
            }
        }

        return order.compactMap { key in
            guard var exercise = grouped[key] else { return nil }
            exercise.sets = exercise.sets.enumerated().map { index, set in
                ExerciseSet(
                    id: set.id,
                    setIndex: index + 1,
                    weight: set.weight,
                    weightUnit: set.weightUnit,
                    reps: set.reps
                )
            }
            return exercise
        }
    }

    private static func normalizedName(for name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func historyDayKey(for date: Date) -> String {
        WorkoutDateFormatter().string(from: date)
    }
}
