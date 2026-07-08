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
        // The plan-child tables (days/exercises/sets) must be scoped to the
        // *selected* plan's id (SY2): once a weekly rotation leaves an
        // archived plan's rows sitting in the same table, an unscoped fetch
        // would pull those in too and they'd get spliced into `activePlan`.
        // That means this fetch can't run concurrently with its children —
        // everything else still can.
        //
        // Selection is by date, not just status='active' (Phase 2): the
        // server generates next week's plan ahead of time (Sunday evening,
        // status='active') without touching the current week, so for a
        // window of up to ~a week two rows can legitimately both be
        // status='active' — this week and next week. Picking the latest one
        // whose week has actually started is what makes Monday's rollover
        // automatic with no separate "activate" step on either side.
        let today = WorkoutDateFormatter().string(from: Date())
        let plans = try await client.fetch(TrainingPlanRow.self, table: "training_plans", query: [
            URLQueryItem(name: "status", value: "eq.active"),
            URLQueryItem(name: "week_start_date", value: "lte.\(today)"),
            URLQueryItem(name: "order", value: "week_start_date.desc"),
            URLQueryItem(name: "limit", value: "1")
        ])
        let activePlanId = plans.first?.id

        async let profiles = client.fetch(ProfileRow.self, table: "profiles", query: [])
        async let preferences = client.fetch(PreferencesRow.self, table: "user_preferences", query: [])
        async let goalSpecs = client.fetch(GoalSpecRow.self, table: "user_goal_specs", query: [])
        async let customs = client.fetch(CustomExerciseRow.self, table: "custom_exercises", query: [])
        async let sessions = client.fetch(WorkoutSessionRow.self, table: "workout_sessions", query: [])
        async let exercises = client.fetch(ExerciseRow.self, table: "exercises", query: [])
        async let sets = client.fetch(ExerciseSetRow.self, table: "exercise_sets", query: [])
        async let running = client.fetch(RunningWorkoutRow.self, table: "running_workouts", query: [])
        async let planDays = fetchScoped(TrainingPlanDayRow.self, table: "training_plan_days", planId: activePlanId)
        async let planExercises = fetchScoped(TrainingPlanExerciseRow.self, table: "training_plan_exercises", planId: activePlanId)
        async let planSets = fetchScoped(TrainingPlanSetRow.self, table: "training_plan_sets", planId: activePlanId)

        return CloudMapper.assembleSnapshot(
            userId: userId,
            profileRow: try await profiles.first,
            preferencesRow: try await preferences.first,
            goalSpecRow: try await goalSpecs.first,
            customRows: try await customs,
            sessionRows: try await sessions,
            exerciseRows: try await exercises,
            setRows: try await sets,
            runningRows: try await running,
            planRows: plans,
            planDayRows: try await planDays,
            planExerciseRows: try await planExercises,
            planSetRows: try await planSets
        )
    }

    /// A no-op (empty result, no request) when there's no active plan yet —
    /// e.g. a brand-new user — rather than fetching unscoped and risking rows
    /// from some other plan.
    private func fetchScoped<Row: Decodable>(_ type: Row.Type, table: String, planId: String?) async throws -> [Row] {
        guard let planId else { return [] }
        return try await client.fetch(type, table: table, query: [URLQueryItem(name: "plan_id", value: "eq.\(planId)")])
    }
}
