import Foundation

// MARK: - Exercise Recommendation Engine
// Deterministic, on-device scoring for the picker's suggested section.
// Single pure entry point so a future model-backed implementation can swap
// in without touching callers.

nonisolated struct RecommendationContext {
    let library: [ExerciseDefinition]
    let sessions: [WorkoutSession]
    /// Everything already chosen for today: picker selection, form cards,
    /// today's plan exercises, and today's logged exercises.
    let todaysSelections: [ExerciseDefinition]
    let today: Date
    let limit: Int

    init(
        library: [ExerciseDefinition],
        sessions: [WorkoutSession],
        todaysSelections: [ExerciseDefinition],
        today: Date,
        limit: Int = 8
    ) {
        self.library = library
        self.sessions = sessions
        self.todaysSelections = todaysSelections
        self.today = today
        self.limit = limit
    }
}

nonisolated enum ExerciseRecommendationEngine {
    /// Big muscle groups need two rest days before reappearing; core and
    /// full-body work can resume after one.
    static let bigGroupRecoveryDays = 2
    static let smallGroupRecoveryDays = 1

    static func synergists(of group: MuscleGroup) -> [MuscleGroup] {
        switch group {
        case .chest: return [.shoulders, .arms]
        case .back: return [.arms]
        case .shoulders: return [.arms]
        case .legs: return [.core]
        case .fullBody: return [.core]
        case .arms, .core: return []
        }
    }

    static func recommend(_ context: RecommendationContext) -> [ExerciseDefinition] {
        guard context.limit > 0, !context.library.isEmpty else { return [] }

        let calendar = Calendar.current
        let lastTrainedDays = lastTrainedDayByGroup(
            sessions: context.sessions,
            library: context.library,
            today: context.today,
            calendar: calendar
        )

        let selectedIds = Set(context.todaysSelections.map(\.id))
        var selectedGroupCounts: [MuscleGroup: Int] = [:]
        for definition in context.todaysSelections {
            selectedGroupCounts[definition.muscleGroup, default: 0] += 1
        }

        // Recovery exclusion. Groups picked or trained today stay eligible:
        // today's direction outranks the rest rule.
        var excludedGroups: Set<MuscleGroup> = []
        for (group, days) in lastTrainedDays {
            guard selectedGroupCounts[group] == nil else { continue }
            let window = (group == .core || group == .fullBody)
                ? smallGroupRecoveryDays
                : bigGroupRecoveryDays
            if days >= 1 && days <= window {
                excludedGroups.insert(group)
            }
        }

        let candidates = context.library.filter { definition in
            !selectedIds.contains(definition.id) && !excludedGroups.contains(definition.muscleGroup)
        }
        guard !candidates.isEmpty else { return [] }

        let personal = personalScores(sessions: context.sessions, library: context.library, today: context.today, calendar: calendar)

        let scored: [(definition: ExerciseDefinition, score: Double)]
        if context.todaysSelections.isEmpty {
            scored = candidates.map { definition in
                let needScore: Double
                if let days = lastTrainedDays[definition.muscleGroup] {
                    needScore = Double(min(days, 7)) / 7
                } else {
                    needScore = 1
                }
                let score = 2 * needScore
                    + 2 * (personal[definition.id] ?? 0)
                    + Double(definition.popularity) / 100
                return (definition, score)
            }
        } else {
            let coScores = coOccurrenceScores(
                sessions: context.sessions,
                library: context.library,
                selectedIds: selectedIds
            )
            scored = candidates.map { definition in
                let score = 3 * (coScores[definition.id] ?? 0)
                    + 2 * affinityScore(for: definition.muscleGroup, selectedGroupCounts: selectedGroupCounts)
                    + 1 * (personal[definition.id] ?? 0)
                    + 0.5 * Double(definition.popularity) / 100
                return (definition, score)
            }
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.definition.popularity != rhs.definition.popularity {
                    return lhs.definition.popularity > rhs.definition.popularity
                }
                return lhs.definition.nameEN < rhs.definition.nameEN
            }
            .prefix(context.limit)
            .map(\.definition)
    }

    /// Folds a freshly computed ranking into the one already on screen without
    /// moving anything: rows in `pinned` keep the slot they were first drawn
    /// in, and `incoming` may only fill slots that are still free.
    ///
    /// The suggested section is a live ranking, so re-scoring it mid-multi-select
    /// used to reshuffle every row (and drop the one just picked) while the
    /// user's finger was already on the way down — reliably turning a tap on
    /// one exercise into a tap on whatever slid into its place. Callers pin for
    /// the length of one picking pass and re-rank from scratch between passes.
    static func stableMerge(
        pinned: [ExerciseDefinition],
        incoming: [ExerciseDefinition],
        limit: Int
    ) -> [ExerciseDefinition] {
        guard limit > 0 else { return [] }
        var merged = Array(pinned.prefix(limit))
        var seenIds = Set(merged.map(\.id))
        for definition in incoming where merged.count < limit {
            guard seenIds.insert(definition.id).inserted else { continue }
            merged.append(definition)
        }
        return merged
    }

    // MARK: - Signals

    /// Calendar days since each muscle group was last trained (0 = today).
    static func lastTrainedDayByGroup(
        sessions: [WorkoutSession],
        library: [ExerciseDefinition],
        today: Date,
        calendar: Calendar
    ) -> [MuscleGroup: Int] {
        let todayStart = calendar.startOfDay(for: today)
        var result: [MuscleGroup: Int] = [:]
        for session in sessions {
            let sessionStart = calendar.startOfDay(for: session.date)
            guard let days = calendar.dateComponents([.day], from: sessionStart, to: todayStart).day,
                  days >= 0 else { continue }
            for exercise in session.exercises {
                guard let definition = ExerciseLibraryEngine.resolveDefinition(
                    name: exercise.name,
                    exerciseId: exercise.exerciseId,
                    in: library
                ) else { continue }
                if let existing = result[definition.muscleGroup] {
                    result[definition.muscleGroup] = min(existing, days)
                } else {
                    result[definition.muscleGroup] = days
                }
            }
        }
        return result
    }

    /// Normalized "trained together in the same session" counts against the
    /// current selection.
    static func coOccurrenceScores(
        sessions: [WorkoutSession],
        library: [ExerciseDefinition],
        selectedIds: Set<String>
    ) -> [String: Double] {
        guard !selectedIds.isEmpty else { return [:] }

        var counts: [String: Int] = [:]
        for session in sessions {
            let sessionIds = Set(session.exercises.compactMap { exercise in
                ExerciseLibraryEngine.resolveDefinition(
                    name: exercise.name,
                    exerciseId: exercise.exerciseId,
                    in: library
                )?.id
            })
            let selectedInSession = sessionIds.intersection(selectedIds)
            guard !selectedInSession.isEmpty else { continue }
            for candidateId in sessionIds.subtracting(selectedIds) {
                counts[candidateId, default: 0] += selectedInSession.count
            }
        }

        guard let maxCount = counts.values.max(), maxCount > 0 else { return [:] }
        return counts.mapValues { Double($0) / Double(maxCount) }
    }

    /// Frequency + recency of each exercise in the user's history, 0...1.
    static func personalScores(
        sessions: [WorkoutSession],
        library: [ExerciseDefinition],
        today: Date,
        calendar: Calendar
    ) -> [String: Double] {
        struct Usage {
            var count = 0
            var lastDays = Int.max
        }

        let todayStart = calendar.startOfDay(for: today)
        var usage: [String: Usage] = [:]
        for session in sessions {
            let sessionStart = calendar.startOfDay(for: session.date)
            guard let days = calendar.dateComponents([.day], from: sessionStart, to: todayStart).day,
                  days >= 0 else { continue }
            for exercise in session.exercises {
                guard let definition = ExerciseLibraryEngine.resolveDefinition(
                    name: exercise.name,
                    exerciseId: exercise.exerciseId,
                    in: library
                ) else { continue }
                var entry = usage[definition.id] ?? Usage()
                entry.count += 1
                entry.lastDays = min(entry.lastDays, days)
                usage[definition.id] = entry
            }
        }

        guard let maxCount = usage.values.map(\.count).max(), maxCount > 0 else { return [:] }
        return usage.mapValues { entry in
            let frequency = Double(entry.count) / Double(maxCount)
            let recency = max(0.0, Double(30 - min(entry.lastDays, 30))) / 30
            return 0.6 * frequency + 0.4 * recency
        }
    }

    /// Same group leads; once a group has three picks it yields to its
    /// synergists so a session progresses instead of stacking one muscle.
    static func affinityScore(
        for group: MuscleGroup,
        selectedGroupCounts: [MuscleGroup: Int]
    ) -> Double {
        if let count = selectedGroupCounts[group] {
            return count >= 3 ? 0.4 : 1.0
        }
        var best = 0.0
        for (selectedGroup, count) in selectedGroupCounts {
            guard synergists(of: selectedGroup).contains(group) else { continue }
            best = max(best, count >= 3 ? 0.8 : 0.6)
        }
        return best
    }
}
