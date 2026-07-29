import Foundation

/// A cloud read plus the fact the destructive half of sync depends on: was
/// every table read all the way to EOF?
///
/// `data` is always safe to *merge* into the cache — merging only ever adds
/// rows and resolves collisions, so a partial read just means fewer cloud rows
/// arrived this time. It is `isComplete` that decides whether the resulting
/// local state may be used as the authority for **deleting** cloud rows: with
/// a truncated read every row past the cutoff is absent from the local cache,
/// and an absence-based prune reads that as "the user deleted it" (Issue #30).
nonisolated struct CloudSnapshot: Sendable {
    let data: LocalDataSnapshot
    /// Tables whose paginated read hit `CloudPagination.maxPages` before EOF.
    /// Empty in every healthy case; named so the log says which table blew up.
    let incompleteTables: [String]

    var isComplete: Bool { incompleteTables.isEmpty }
}

/// The read path: fetch every table the app caches and assemble one
/// `LocalDataSnapshot`. Child tables are fetched flat and re-nested in the
/// mapper — RLS scopes all of it to the signed-in user, so no per-request
/// user filter is needed.
nonisolated struct CloudSnapshotLoader: Sendable {
    private let client: SupabaseDataClient

    init(client: SupabaseDataClient) {
        self.client = client
    }

    func load(userId: String) async throws -> CloudSnapshot {
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
        //
        // Deliberately not paginated: `limit=1` bounds it by construction.
        // `training_plans` is the one growing table we never read in full —
        // the cache only ever holds the current week (SY1), which is also why
        // it is never pruned.
        let today = WorkoutDateFormatter().string(from: Date())
        let plans = try await client.fetch(TrainingPlanRow.self, table: "training_plans", query: [
            URLQueryItem(name: "status", value: "eq.active"),
            URLQueryItem(name: "week_start_date", value: "lte.\(today)"),
            URLQueryItem(name: "order", value: "week_start_date.desc"),
            URLQueryItem(name: "limit", value: "1")
        ])
        let activePlanId = plans.first?.id

        // profiles / user_preferences / user_goal_specs are exactly one row
        // per user — PK or UNIQUE on the user id, and RLS restricts each of
        // them to `auth.uid()`. `max_rows` cannot truncate a one-row result,
        // so they stay single-request; only tables that grow with training
        // history need the paging loop.
        async let profiles = client.fetch(ProfileRow.self, table: "profiles", query: [])
        async let preferences = client.fetch(PreferencesRow.self, table: "user_preferences", query: [])
        async let goalSpecs = client.fetch(GoalSpecRow.self, table: "user_goal_specs", query: [])

        // Everything below grows without bound with the user's history, so a
        // plain fetch silently stops at PostgREST's `max_rows` (1000). Each of
        // these reads to EOF and reports whether it got there.
        async let customs = client.fetchAllPages(CustomExerciseRow.self, table: "custom_exercises", key: { $0.id })
        async let sessions = client.fetchAllPages(WorkoutSessionRow.self, table: "workout_sessions", key: { $0.id })
        async let exercises = client.fetchAllPages(ExerciseRow.self, table: "exercises", key: { $0.id })
        async let sets = client.fetchAllPages(ExerciseSetRow.self, table: "exercise_sets", key: { $0.id })
        async let running = client.fetchAllPages(RunningWorkoutRow.self, table: "running_workouts", key: { $0.id })
        async let planDays = fetchScoped(TrainingPlanDayRow.self, table: "training_plan_days", planId: activePlanId, key: { $0.id })
        async let planExercises = fetchScoped(TrainingPlanExerciseRow.self, table: "training_plan_exercises", planId: activePlanId, key: { $0.id })
        async let planSets = fetchScoped(TrainingPlanSetRow.self, table: "training_plan_sets", planId: activePlanId, key: { $0.id })

        let customsPage = try await customs
        let sessionsPage = try await sessions
        let exercisesPage = try await exercises
        let setsPage = try await sets
        let runningPage = try await running
        let planDaysPage = try await planDays
        let planExercisesPage = try await planExercises
        let planSetsPage = try await planSets

        let data = CloudMapper.assembleSnapshot(
            userId: userId,
            profileRow: try await profiles.first,
            preferencesRow: try await preferences.first,
            goalSpecRow: try await goalSpecs.first,
            customRows: customsPage.elements,
            sessionRows: sessionsPage.elements,
            exerciseRows: exercisesPage.elements,
            setRows: setsPage.elements,
            runningRows: runningPage.elements,
            planRows: plans,
            planDayRows: planDaysPage.elements,
            planExerciseRows: planExercisesPage.elements,
            planSetRows: planSetsPage.elements
        )

        let incompleteTables = [
            ("custom_exercises", customsPage.isComplete),
            ("workout_sessions", sessionsPage.isComplete),
            ("exercises", exercisesPage.isComplete),
            ("exercise_sets", setsPage.isComplete),
            ("running_workouts", runningPage.isComplete),
            ("training_plan_days", planDaysPage.isComplete),
            ("training_plan_exercises", planExercisesPage.isComplete),
            ("training_plan_sets", planSetsPage.isComplete)
        ].filter { !$0.1 }.map(\.0)

        return CloudSnapshot(data: data, incompleteTables: incompleteTables)
    }

    /// A no-op (empty result, no request) when there's no active plan yet —
    /// e.g. a brand-new user — rather than fetching unscoped and risking rows
    /// from some other plan. Reported complete, because "this plan has no
    /// children" is a fact, not a truncation.
    private func fetchScoped<Row: Decodable & Sendable>(
        _ type: Row.Type,
        table: String,
        planId: String?,
        key: @escaping @Sendable (Row) -> String
    ) async throws -> CloudPagedResult<Row> {
        guard let planId else { return CloudPagedResult(elements: [], isComplete: true) }
        return try await client.fetchAllPages(
            type,
            table: table,
            query: [URLQueryItem(name: "plan_id", value: "eq.\(planId)")],
            key: key
        )
    }
}
