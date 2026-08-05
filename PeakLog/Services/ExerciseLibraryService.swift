import Foundation

// MARK: - Recent Exercise Entry
// A library exercise enriched with the user's actual training history,
// shown in the picker's "recent" section.

nonisolated struct RecentExerciseEntry: Identifiable, Equatable, Sendable {
    let definition: ExerciseDefinition
    let lastPerformedAt: Date
    let timesPerformed: Int
    let lastWeight: Double?
    let lastWeightUnit: WeightUnit
    let lastReps: Int?

    // Prefixed so a recent row and its library row can coexist in one list
    // without colliding on SwiftUI identity.
    var id: String { "recent-\(definition.id)" }
}

// MARK: - Library Engine
// Pure functions over in-memory data so the search/recent rules can be
// exercised by tests/ scripts without a bundle or database.

nonisolated enum ExerciseLibraryEngine {
    static func merged(seed: [ExerciseDefinition], custom: [ExerciseDefinition]) -> [ExerciseDefinition] {
        seed + custom.filter { customDefinition in
            !seed.contains { $0.id == customDefinition.id }
        }
    }

    static func filter(
        _ exercises: [ExerciseDefinition],
        query: String = "",
        muscleGroup: MuscleGroup? = nil,
        equipment: Equipment? = nil
    ) -> [ExerciseDefinition] {
        exercises.filter { exercise in
            if let muscleGroup, exercise.muscleGroup != muscleGroup { return false }
            if let equipment, exercise.equipment != equipment { return false }
            return exercise.matches(query: query)
        }
    }

    /// Groups follow MuscleGroup.allCases order; exercises within a group are
    /// sorted by popularity so common movements surface first.
    static func groupedByMuscle(_ exercises: [ExerciseDefinition]) -> [(group: MuscleGroup, exercises: [ExerciseDefinition])] {
        MuscleGroup.allCases.compactMap { group in
            let matching = exercises
                .filter { $0.muscleGroup == group }
                .sorted { lhs, rhs in
                    if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
                    return lhs.nameEN < rhs.nameEN
                }
            return matching.isEmpty ? nil : (group, matching)
        }
    }

    /// Resolves a logged exercise back to a library definition — by stable id
    /// first, then by exact normalized name/alias match for legacy entries.
    static func resolveDefinition(
        name: String,
        exerciseId: String?,
        in library: [ExerciseDefinition]
    ) -> ExerciseDefinition? {
        if let exerciseId, let byId = library.first(where: { $0.id == exerciseId }) {
            return byId
        }
        let normalized = ExerciseDefinition.normalize(name)
        guard !normalized.isEmpty else { return nil }
        return library.first { definition in
            ExerciseDefinition.normalize(definition.nameEN) == normalized
                || ExerciseDefinition.normalize(definition.nameZH) == normalized
                || definition.aliases.contains { ExerciseDefinition.normalize($0) == normalized }
        }
    }

    static func exactNameMatch(_ query: String, in library: [ExerciseDefinition]) -> ExerciseDefinition? {
        resolveDefinition(name: query, exerciseId: nil, in: library)
    }

    /// Derives the "recent" section from actual training history: most recent
    /// session date first, ties broken by how often the exercise was performed.
    static func recentEntries(
        sessions: [WorkoutSession],
        library: [ExerciseDefinition],
        limit: Int = 10
    ) -> [RecentExerciseEntry] {
        struct Accumulator {
            var definition: ExerciseDefinition
            var lastPerformedAt: Date
            var timesPerformed: Int
            var lastTopSet: ExerciseSet?
        }

        var byDefinitionId: [String: Accumulator] = [:]

        for session in sessions {
            for exercise in session.exercises {
                guard let definition = resolveDefinition(
                    name: exercise.name,
                    exerciseId: exercise.exerciseId,
                    in: library
                ) else { continue }

                let topSet = exercise.sets.max { lhs, rhs in
                    (lhs.weight ?? 0, lhs.reps) < (rhs.weight ?? 0, rhs.reps)
                }

                if var existing = byDefinitionId[definition.id] {
                    existing.timesPerformed += 1
                    if session.date > existing.lastPerformedAt {
                        existing.lastPerformedAt = session.date
                        existing.lastTopSet = topSet
                    }
                    byDefinitionId[definition.id] = existing
                } else {
                    byDefinitionId[definition.id] = Accumulator(
                        definition: definition,
                        lastPerformedAt: session.date,
                        timesPerformed: 1,
                        lastTopSet: topSet
                    )
                }
            }
        }

        return byDefinitionId.values
            .sorted { lhs, rhs in
                if lhs.lastPerformedAt != rhs.lastPerformedAt { return lhs.lastPerformedAt > rhs.lastPerformedAt }
                if lhs.timesPerformed != rhs.timesPerformed { return lhs.timesPerformed > rhs.timesPerformed }
                return lhs.definition.nameEN < rhs.definition.nameEN
            }
            .prefix(limit)
            .map { accumulator in
                RecentExerciseEntry(
                    definition: accumulator.definition,
                    lastPerformedAt: accumulator.lastPerformedAt,
                    timesPerformed: accumulator.timesPerformed,
                    lastWeight: accumulator.lastTopSet?.weight,
                    lastWeightUnit: accumulator.lastTopSet?.weightUnit ?? .kg,
                    lastReps: accumulator.lastTopSet?.reps
                )
            }
    }

    /// The library definitions the user has already committed to today —
    /// whatever today's plan lists, plus whatever has actually been logged.
    /// Takes the plan day and the full session list as parameters rather than
    /// reading them itself, so the caller can fetch once and so this stays
    /// testable without a database.
    static func todaysTrainedDefinitions(
        library: [ExerciseDefinition],
        todayPlanDay: TrainingPlanDay?,
        sessions: [WorkoutSession],
        today: Date,
        calendar: Calendar = .current
    ) -> [ExerciseDefinition] {
        var definitions: [ExerciseDefinition] = []
        for exercise in todayPlanDay?.exercises ?? [] {
            if let definition = resolveDefinition(
                name: exercise.exerciseName,
                exerciseId: exercise.exerciseId,
                in: library
            ) {
                definitions.append(definition)
            }
        }
        let todaysSessions = sessions
            .filter { calendar.isDate($0.date, inSameDayAs: today) }
            .sorted { $0.createdAt < $1.createdAt }
        for session in todaysSessions {
            for exercise in session.exercises {
                if let definition = resolveDefinition(
                    name: exercise.name,
                    exerciseId: exercise.exerciseId,
                    in: library
                ) {
                    definitions.append(definition)
                }
            }
        }
        return definitions
    }

    /// The full per-set breakdown (weight × reps for every set, in order)
    /// from the most recent session that included this exercise. Used to
    /// prefill a new set's weight/reps with what was actually done last time,
    /// as opposed to `recentEntries`'s single top-set summary.
    static func lastPerformedSets(
        exerciseId: String?,
        exerciseName: String,
        sessions: [WorkoutSession],
        library: [ExerciseDefinition],
        before: Date? = nil,
        calendar: Calendar = .current
    ) -> [ExerciseSet]? {
        guard let definition = resolveDefinition(name: exerciseName, exerciseId: exerciseId, in: library) else {
            return nil
        }

        func matches(_ exercise: Exercise) -> Bool {
            resolveDefinition(name: exercise.name, exerciseId: exercise.exerciseId, in: library)?.id == definition.id
        }

        // `before` 传入时按「自然日」裁剪：训练中要看的是**上一次**的数字，
        // 今天自己刚落库的组不能算，否则一边练一边把参照物覆盖掉。
        let candidates: [WorkoutSession]
        if let before {
            let startOfDay = calendar.startOfDay(for: before)
            candidates = sessions.filter { $0.date < startOfDay }
        } else {
            candidates = sessions
        }

        guard let latestSession = candidates
            .filter({ $0.exercises.contains(where: matches) })
            .max(by: { $0.date < $1.date }),
            let exercise = latestSession.exercises.first(where: matches)
        else {
            return nil
        }

        return exercise.sets.sorted { $0.setIndex < $1.setIndex }
    }
}

// MARK: - Seed Library Loading

nonisolated enum ExerciseSeedLibrary {
    /// The seed is ~1,300 entries, and `fetchLibrary()` is called on every
    /// picker appearance and recommendation refresh, so the main-bundle copy is
    /// decoded once and shared. `static let` gives us the thread-safe lazy init.
    private static let mainBundleSeed: [ExerciseDefinition] = decode(bundle: .main)

    static func load(bundle: Bundle = .main) -> [ExerciseDefinition] {
        bundle === Bundle.main ? mainBundleSeed : decode(bundle: bundle)
    }

    private static func decode(bundle: Bundle) -> [ExerciseDefinition] {
        guard let url = bundle.url(forResource: "exercise_library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ExerciseLibraryFile.self, from: data) else {
            return []
        }
        return file.exercises
    }
}

// MARK: - Service

protocol ExerciseLibraryServiceProtocol {
    func fetchLibrary() async -> [ExerciseDefinition]
    func fetchRecentEntries(limit: Int) async -> [RecentExerciseEntry]
    func fetchRecommendations(
        todaysSelections: [ExerciseDefinition],
        limit: Int
    ) async -> [ExerciseDefinition]
    func addCustomExercise(
        name: String,
        muscleGroup: MuscleGroup,
        loadType: ExerciseLoadType
    ) async throws -> ExerciseDefinition
    func fetchLastPerformedSets(exerciseId: String?, exerciseName: String) async -> [ExerciseSet]?
    /// 同上，但只看 `date` 所在自然日**之前**的记录。训练中展示「上次成绩」用这个：
    /// 今天已落库的组不能当成参照物。
    func fetchLastPerformedSets(
        exerciseId: String?,
        exerciseName: String,
        before date: Date
    ) async -> [ExerciseSet]?
}

final class LocalExerciseLibraryService: ExerciseLibraryServiceProtocol {
    private let database: LocalAppDatabase
    private let seed: [ExerciseDefinition]

    init(database: LocalAppDatabase, seed: [ExerciseDefinition] = ExerciseSeedLibrary.load()) {
        self.database = database
        self.seed = seed
    }

    func fetchLibrary() async -> [ExerciseDefinition] {
        ExerciseLibraryEngine.merged(seed: seed, custom: await database.customExercises())
    }

    func fetchRecentEntries(limit: Int = 10) async -> [RecentExerciseEntry] {
        ExerciseLibraryEngine.recentEntries(
            sessions: await database.allStrengthSessions(),
            library: await fetchLibrary(),
            limit: limit
        )
    }

    func fetchLastPerformedSets(exerciseId: String?, exerciseName: String) async -> [ExerciseSet]? {
        ExerciseLibraryEngine.lastPerformedSets(
            exerciseId: exerciseId,
            exerciseName: exerciseName,
            sessions: await database.allStrengthSessions(),
            library: await fetchLibrary()
        )
    }

    func fetchLastPerformedSets(
        exerciseId: String?,
        exerciseName: String,
        before date: Date
    ) async -> [ExerciseSet]? {
        ExerciseLibraryEngine.lastPerformedSets(
            exerciseId: exerciseId,
            exerciseName: exerciseName,
            sessions: await database.allStrengthSessions(),
            library: await fetchLibrary(),
            before: date
        )
    }

    /// Context-aware picks for the picker's suggested section. The caller
    /// passes what is already chosen in the current flow; today's plan and
    /// today's logged exercises are merged in here.
    func fetchRecommendations(
        todaysSelections: [ExerciseDefinition],
        limit: Int = 8
    ) async -> [ExerciseDefinition] {
        // One read of each input per recommendation, taken here at the entry
        // point rather than cached on the instance: caching in `init` would
        // make a picker opened after a set was logged recommend against stale
        // history. Everything below is a pure function of what was fetched.
        let library = await fetchLibrary()
        let sessions = await database.allStrengthSessions()
        let todayPlanDay = await database.todayPlan()
        let today = Date()

        var combined: [String: ExerciseDefinition] = [:]
        for definition in todaysSelections {
            combined[definition.id] = definition
        }
        for definition in ExerciseLibraryEngine.todaysTrainedDefinitions(
            library: library,
            todayPlanDay: todayPlanDay,
            sessions: sessions,
            today: today
        ) {
            combined[definition.id] = definition
        }

        return ExerciseRecommendationEngine.recommend(
            RecommendationContext(
                library: library,
                sessions: sessions,
                todaysSelections: Array(combined.values),
                today: today,
                limit: limit
            )
        )
    }

    func addCustomExercise(
        name: String,
        muscleGroup: MuscleGroup,
        loadType: ExerciseLoadType
    ) async throws -> ExerciseDefinition {
        // Creating a name that already exists (seed or custom) selects the
        // existing definition instead of minting a duplicate.
        if let existing = ExerciseLibraryEngine.exactNameMatch(name, in: await fetchLibrary()) {
            return existing
        }
        return try await database.addCustomExercise(
            name: name,
            muscleGroup: muscleGroup,
            loadType: loadType
        )
    }
}
