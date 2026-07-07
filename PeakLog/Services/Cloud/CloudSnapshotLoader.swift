import Foundation

/// The read path: fetch every table the app caches and assemble one
/// `LocalDataSnapshot`. Child tables are fetched flat and re-nested in the
/// mapper — RLS scopes all of it to the signed-in user, so no per-request
/// user filter is needed.
nonisolated struct CloudSnapshotLoader: Sendable {
    private let client: SupabaseDataClient

    init(client: SupabaseDataClient) {
        self.client = client
    }

    func load(userId: String) async throws -> LocalDataSnapshot {
        // Independent reads run concurrently; order doesn't matter for a pull.
        async let profiles = client.fetch(ProfileRow.self, table: "profiles", query: [])
        async let preferences = client.fetch(PreferencesRow.self, table: "user_preferences", query: [])
        async let customs = client.fetch(CustomExerciseRow.self, table: "custom_exercises", query: [])
        async let sessions = client.fetch(WorkoutSessionRow.self, table: "workout_sessions", query: [])
        async let exercises = client.fetch(ExerciseRow.self, table: "exercises", query: [])
        async let sets = client.fetch(ExerciseSetRow.self, table: "exercise_sets", query: [])
        async let running = client.fetch(RunningWorkoutRow.self, table: "running_workouts", query: [])
        async let plans = client.fetch(TrainingPlanRow.self, table: "training_plans", query: [
            URLQueryItem(name: "status", value: "eq.active"),
            URLQueryItem(name: "order", value: "week_start_date.desc"),
            URLQueryItem(name: "limit", value: "1")
        ])
        async let planDays = client.fetch(TrainingPlanDayRow.self, table: "training_plan_days", query: [])
        async let planExercises = client.fetch(TrainingPlanExerciseRow.self, table: "training_plan_exercises", query: [])
        async let planSets = client.fetch(TrainingPlanSetRow.self, table: "training_plan_sets", query: [])

        return CloudMapper.assembleSnapshot(
            userId: userId,
            profileRow: try await profiles.first,
            preferencesRow: try await preferences.first,
            customRows: try await customs,
            sessionRows: try await sessions,
            exerciseRows: try await exercises,
            setRows: try await sets,
            runningRows: try await running,
            planRows: try await plans,
            planDayRows: try await planDays,
            planExerciseRows: try await planExercises,
            planSetRows: try await planSets
        )
    }
}
