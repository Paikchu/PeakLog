import Foundation

/// All rows for a full push, grouped by table in FK-safe upsert order.
nonisolated struct CloudPushBundle: Sendable {
    var profile: ProfileRow
    var preferences: PreferencesRow
    /// nil when the user has never saved a goal — pushing skips the upsert
    /// rather than writing a synthetic default row (G5).
    var goalSpec: GoalSpecRow?
    var customExercises: [CustomExerciseRow]
    var sessions: [WorkoutSessionRow]
    var exercises: [ExerciseRow]
    var exerciseSets: [ExerciseSetRow]
    var running: [RunningWorkoutRow]
    var plans: [TrainingPlanRow]
    var planDays: [TrainingPlanDayRow]
    var planExercises: [TrainingPlanExerciseRow]
    var planSets: [TrainingPlanSetRow]
    /// Not-yet-pushed edit events. Inserted (never upserted/pruned) — see
    /// `SupabaseDataClient.insertIgnoringDuplicates`.
    var editEvents: [PlanEditEventRow]
}

nonisolated enum CloudMappingError: Error, Equatable {
    case accountMismatch(expected: String, actual: String, recordType: String, recordId: String)
}

/// Translates between domain models and PostgREST rows. Pure and static so the
/// mapping is unit-testable without any network.
nonisolated enum CloudMapper {

    // MARK: - Domain → rows (push)

    static func pushBundle(from snapshot: LocalDataSnapshot, userId: String) throws -> CloudPushBundle {
        try validateOwnership(of: snapshot, userId: userId)
        var exercises: [ExerciseRow] = []
        var exerciseSets: [ExerciseSetRow] = []
        for session in snapshot.strengthSessions {
            for (exerciseIndex, exercise) in session.exercises.enumerated() {
                exercises.append(ExerciseRow(
                    id: exercise.id,
                    session_id: session.id,
                    user_id: userId,
                    name: exercise.name,
                    normalized_name: exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    exercise_id: exercise.exerciseId,
                    exercise_load_type: (exercise.exerciseLoadType ?? .unknown).rawValue,
                    order_index: exerciseIndex
                ))
                for set in exercise.sets {
                    exerciseSets.append(ExerciseSetRow(
                        id: set.id,
                        exercise_id: exercise.id,
                        user_id: userId,
                        set_index: set.setIndex,
                        weight: set.weight,
                        weight_unit: set.weightUnit.rawValue,
                        reps: set.reps,
                        rpe: set.rpe
                    ))
                }
            }
        }

        var planDays: [TrainingPlanDayRow] = []
        var planExercises: [TrainingPlanExerciseRow] = []
        var planSets: [TrainingPlanSetRow] = []
        let plan = snapshot.activePlan
        for day in plan.days {
            planDays.append(TrainingPlanDayRow(
                id: day.id,
                plan_id: plan.id,
                user_id: userId,
                plan_date: day.planDate,
                day_index: day.dayIndex,
                title: day.title,
                focus: day.focus,
                status: day.status
            ))
            for exercise in day.exercises {
                planExercises.append(TrainingPlanExerciseRow(
                    id: exercise.id,
                    plan_id: plan.id,
                    plan_day_id: day.id,
                    user_id: userId,
                    order_index: exercise.orderIndex,
                    exercise_name: exercise.exerciseName,
                    exercise_id: exercise.exerciseId,
                    progression_mode: exercise.progressionMode,
                    exercise_load_type: exercise.exerciseLoadType.rawValue,
                    notes: exercise.notes
                ))
                for set in exercise.sets {
                    planSets.append(TrainingPlanSetRow(
                        id: set.id,
                        plan_id: plan.id,
                        plan_exercise_id: exercise.id,
                        user_id: userId,
                        set_index: set.setIndex,
                        target_weight: set.targetWeight,
                        target_weight_unit: set.targetWeightUnit.rawValue,
                        target_reps: set.targetReps,
                        completed_at: set.completedAt.map(CloudDate.timestampString(from:)),
                        linked_exercise_set_id: set.linkedExerciseSetId
                    ))
                }
            }
        }

        return CloudPushBundle(
            profile: profileRow(from: snapshot.profile),
            preferences: preferencesRow(from: snapshot.profile),
            goalSpec: snapshot.goalSpec.map { goalSpecRow(from: $0, userId: userId) },
            customExercises: snapshot.customExercises.map { customRow(from: $0, userId: userId) },
            sessions: snapshot.strengthSessions.map { sessionRow(from: $0, userId: userId) },
            exercises: exercises,
            exerciseSets: exerciseSets,
            running: snapshot.runningRecords.map { runningRow(from: $0, userId: userId) },
            plans: [planRow(from: plan, userId: userId)],
            planDays: planDays,
            planExercises: planExercises,
            planSets: planSets,
            editEvents: snapshot.pendingEditEvents.map(planEditEventRow(from:))
        )
    }

    private static func validateOwnership(of snapshot: LocalDataSnapshot, userId: String) throws {
        guard snapshot.profile.id == userId else {
            throw CloudMappingError.accountMismatch(
                expected: userId,
                actual: snapshot.profile.id,
                recordType: "profile",
                recordId: snapshot.profile.id
            )
        }
        for session in snapshot.strengthSessions where session.userId != userId {
            throw CloudMappingError.accountMismatch(
                expected: userId,
                actual: session.userId,
                recordType: "workoutSession",
                recordId: session.id
            )
        }
        for record in snapshot.runningRecords where record.userId != userId {
            throw CloudMappingError.accountMismatch(
                expected: userId,
                actual: record.userId,
                recordType: "runningWorkout",
                recordId: record.id
            )
        }
        for event in snapshot.pendingEditEvents where event.userId != userId {
            throw CloudMappingError.accountMismatch(
                expected: userId,
                actual: event.userId,
                recordType: "planEditEvent",
                recordId: event.id
            )
        }
    }

    static func goalSpecRow(from spec: GoalSpec, userId: String) -> GoalSpecRow {
        GoalSpecRow(
            user_id: userId,
            objective: spec.objective.rawValue,
            days_per_week: spec.daysPerWeek,
            session_minutes: spec.sessionMinutes,
            equipment: spec.equipment.map(\.rawValue),
            focus_areas: spec.focusAreas.map(\.rawValue),
            experience: spec.experience.rawValue,
            note: spec.note
        )
    }

    static func planEditEventRow(from event: PlanEditEvent) -> PlanEditEventRow {
        PlanEditEventRow(
            id: event.id,
            user_id: event.userId,
            plan_id: event.planId,
            plan_day_id: event.planDayId,
            plan_date: event.planDate,
            event_type: event.eventType.rawValue,
            exercise_name: event.exerciseName,
            exercise_id: event.exerciseId,
            payload: event.payload,
            source: event.source.rawValue,
            client_seq: event.clientSeq,
            occurred_at: CloudDate.timestampString(from: event.occurredAt)
        )
    }

    static func profileRow(from profile: UserProfile) -> ProfileRow {
        ProfileRow(
            id: profile.id,
            display_name: profile.displayName,
            avatar_url: profile.avatarURL?.absoluteString,
            membership_type: profile.membershipLevel.rawValue,
            timezone: profile.preferences.timezone,
            fitness_goal_summary: profile.fitnessGoalSummary
        )
    }

    static func preferencesRow(from profile: UserProfile) -> PreferencesRow {
        PreferencesRow(
            user_id: profile.id,
            notifications_enabled: profile.preferences.notificationsEnabled,
            weight_unit: profile.preferences.weightUnit.rawValue,
            language: profile.preferences.language.rawValue
        )
    }

    static func sessionRow(from session: WorkoutSession, userId: String) -> WorkoutSessionRow {
        WorkoutSessionRow(
            id: session.id,
            user_id: userId,
            workout_date: CloudDate.dayString(from: session.date),
            title: session.label,
            source_type: "manual",
            duration_seconds: session.durationMinutes.map { $0 * 60 },
            created_at: CloudDate.timestampString(from: session.createdAt),
            updated_at: CloudDate.timestampString(from: session.updatedAt)
        )
    }

    static func runningRow(from record: RunningWorkoutRecord, userId: String) -> RunningWorkoutRow {
        RunningWorkoutRow(
            id: record.id,
            user_id: userId,
            workout_date: CloudDate.dayString(from: record.workoutDate),
            duration_minutes: record.durationMinutes,
            distance_km: record.distanceKm,
            source: record.source == .agent ? "agent" : "manual",
            created_at: CloudDate.timestampString(from: record.createdAt),
            updated_at: CloudDate.timestampString(from: record.updatedAt)
        )
    }

    static func planRow(from plan: TrainingPlan, userId: String) -> TrainingPlanRow {
        TrainingPlanRow(
            id: plan.id,
            user_id: userId,
            week_start_date: plan.weekStartDate,
            status: "active",
            goal_snapshot: plan.goalSummary,
            coach_summary: plan.coachSummary
        )
    }

    static func customRow(from definition: ExerciseDefinition, userId: String) -> CustomExerciseRow {
        CustomExerciseRow(
            id: strippedCustomId(definition.id),
            user_id: userId,
            name_en: definition.nameEN,
            name_zh: definition.nameZH,
            aliases: definition.aliases,
            muscle_group: definition.muscleGroup.rawValue,
            equipment: definition.equipment.rawValue,
            load_type: definition.loadType.rawValue,
            popularity: definition.popularity
        )
    }

    // MARK: - Rows → domain (pull)

    static func assembleSnapshot(
        userId: String,
        profileRow: ProfileRow?,
        preferencesRow: PreferencesRow?,
        goalSpecRow: GoalSpecRow?,
        customRows: [CustomExerciseRow],
        sessionRows: [WorkoutSessionRow],
        exerciseRows: [ExerciseRow],
        setRows: [ExerciseSetRow],
        runningRows: [RunningWorkoutRow],
        planRows: [TrainingPlanRow],
        planDayRows: [TrainingPlanDayRow],
        planExerciseRows: [TrainingPlanExerciseRow],
        planSetRows: [TrainingPlanSetRow]
    ) -> LocalDataSnapshot {
        LocalDataSnapshot(
            profile: profile(userId: userId, profileRow: profileRow, preferencesRow: preferencesRow),
            activePlan: plan(userId: userId, planRows: planRows, dayRows: planDayRows, exerciseRows: planExerciseRows, setRows: planSetRows),
            strengthSessions: sessions(sessionRows: sessionRows, exerciseRows: exerciseRows, setRows: setRows),
            runningRecords: runningRows.map(running(from:)),
            customExercises: customRows.map(custom(from:)),
            goalSpec: goalSpec(from: goalSpecRow),
            // A pull assembles cloud truth, not local outbox facts — the
            // caller's `replaceAll` doesn't even accept this field (EV1).
            pendingEditEvents: []
        )
    }

    static func goalSpec(from row: GoalSpecRow?) -> GoalSpec? {
        guard let row else { return nil }
        return GoalSpec(
            objective: GoalObjective(rawValue: row.objective) ?? .general,
            daysPerWeek: row.days_per_week,
            sessionMinutes: row.session_minutes,
            equipment: row.equipment.compactMap(Equipment.init(rawValue:)),
            focusAreas: row.focus_areas.compactMap(MuscleGroup.init(rawValue:)),
            experience: ExperienceLevel(rawValue: row.experience) ?? .beginner,
            note: row.note
        )
    }

    static func profile(userId: String, profileRow: ProfileRow?, preferencesRow: PreferencesRow?) -> UserProfile {
        // A brand-new signup has no profile/preferences rows yet; fall back
        // to the same `UserPreferences.defaults` the local seed uses so the
        // "never configured" boundary is defined in one place (Issue #35).
        // `darkModeEnabled` is device-local and never synced — the value
        // assembled here is a placeholder that `mergeFromCloud`/`replaceAll`
        // replace with the local one.
        let defaults = UserPreferences.defaults(timezone: profileRow?.timezone ?? "UTC")
        let preferences = UserPreferences(
            notificationsEnabled: preferencesRow?.notifications_enabled ?? defaults.notificationsEnabled,
            darkModeEnabled: defaults.darkModeEnabled,
            weightUnit: preferencesRow.flatMap { WeightUnit(rawValue: $0.weight_unit) } ?? defaults.weightUnit,
            timezone: defaults.timezone,
            language: preferencesRow.flatMap { AppLanguage(rawValue: $0.language) } ?? defaults.language
        )
        return UserProfile(
            id: profileRow?.id ?? userId,
            displayName: profileRow?.display_name ?? "PeakLog User",
            avatarURL: profileRow?.avatar_url.flatMap(URL.init(string:)),
            membershipLevel: profileRow.flatMap { MembershipLevel(rawValue: $0.membership_type) } ?? .free,
            stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: 0, prCount: 0),
            preferences: preferences,
            fitnessGoalSummary: profileRow?.fitness_goal_summary,
            exercisePRs: []
        )
    }

    static func plan(
        userId: String,
        planRows: [TrainingPlanRow],
        dayRows: [TrainingPlanDayRow],
        exerciseRows: [TrainingPlanExerciseRow],
        setRows: [TrainingPlanSetRow]
    ) -> TrainingPlan {
        guard let planRow = planRows.first else { return emptyPlan() }

        let setsByExercise = Dictionary(grouping: setRows, by: \.plan_exercise_id)
        let exercisesByDay = Dictionary(grouping: exerciseRows, by: \.plan_day_id)

        let days = dayRows
            .filter { $0.plan_id == planRow.id }
            .sorted { $0.day_index < $1.day_index }
            .map { dayRow -> TrainingPlanDay in
                let exercises = (exercisesByDay[dayRow.id] ?? [])
                    .sorted { $0.order_index < $1.order_index }
                    .map { exerciseRow -> TrainingPlanExercise in
                        let sets = (setsByExercise[exerciseRow.id] ?? [])
                            .sorted { $0.set_index < $1.set_index }
                            .map { setRow in
                                TrainingPlanSet(
                                    id: setRow.id,
                                    setIndex: setRow.set_index,
                                    targetWeight: setRow.target_weight,
                                    targetWeightUnit: WeightUnit(rawValue: setRow.target_weight_unit) ?? .kg,
                                    targetReps: setRow.target_reps,
                                    completedAt: CloudDate.timestamp(from: setRow.completed_at),
                                    linkedExerciseSetId: setRow.linked_exercise_set_id
                                )
                            }
                        return TrainingPlanExercise(
                            id: exerciseRow.id,
                            orderIndex: exerciseRow.order_index,
                            exerciseName: exerciseRow.exercise_name,
                            exerciseId: exerciseRow.exercise_id,
                            exerciseLoadType: ExerciseLoadType(rawValue: exerciseRow.exercise_load_type) ?? .unknown,
                            progressionMode: exerciseRow.progression_mode,
                            notes: exerciseRow.notes,
                            previousPerformanceSummary: nil,
                            aiSuggestion: nil,
                            sets: sets
                        )
                    }
                return TrainingPlanDay(
                    id: dayRow.id,
                    planDate: dayRow.plan_date,
                    dayIndex: dayRow.day_index,
                    title: dayRow.title,
                    focus: dayRow.focus,
                    status: dayRow.status,
                    exercises: exercises
                )
            }

        return TrainingPlan(
            id: planRow.id,
            weekStartDate: planRow.week_start_date,
            goalSummary: planRow.goal_snapshot,
            coachSummary: planRow.coach_summary,
            days: days,
            revision: planRow.revision
        )
    }

    static func sessions(
        sessionRows: [WorkoutSessionRow],
        exerciseRows: [ExerciseRow],
        setRows: [ExerciseSetRow]
    ) -> [WorkoutSession] {
        let setsByExercise = Dictionary(grouping: setRows, by: \.exercise_id)
        let exercisesBySession = Dictionary(grouping: exerciseRows, by: \.session_id)

        return sessionRows.map { sessionRow in
            let exercises = (exercisesBySession[sessionRow.id] ?? [])
                .sorted { $0.order_index < $1.order_index }
                .map { exerciseRow -> Exercise in
                    let sets = (setsByExercise[exerciseRow.id] ?? [])
                        .sorted { $0.set_index < $1.set_index }
                        .map { setRow in
                            ExerciseSet(
                                id: setRow.id,
                                setIndex: setRow.set_index,
                                weight: setRow.weight,
                                weightUnit: WeightUnit(rawValue: setRow.weight_unit) ?? .kg,
                                reps: setRow.reps ?? 0,
                                rpe: setRow.rpe
                            )
                        }
                    return Exercise(
                        id: exerciseRow.id,
                        name: exerciseRow.name,
                        exerciseId: exerciseRow.exercise_id,
                        exerciseLoadType: ExerciseLoadType(rawValue: exerciseRow.exercise_load_type),
                        sets: sets
                    )
                }
            let date = CloudDate.day(from: sessionRow.workout_date) ?? Date()
            return WorkoutSession(
                id: sessionRow.id,
                userId: sessionRow.user_id,
                date: date,
                durationMinutes: sessionRow.duration_seconds.map { $0 / 60 },
                label: sessionRow.title,
                exercises: exercises,
                createdAt: CloudDate.timestamp(from: sessionRow.created_at) ?? date,
                updatedAt: CloudDate.timestamp(from: sessionRow.updated_at) ?? date
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    static func running(from row: RunningWorkoutRow) -> RunningWorkoutRecord {
        let date = CloudDate.day(from: row.workout_date) ?? Date()
        return RunningWorkoutRecord(
            id: row.id,
            userId: row.user_id,
            workoutDate: date,
            durationMinutes: row.duration_minutes,
            distanceKm: row.distance_km,
            source: RunningWorkoutSource(rawValue: row.source) ?? .manual,
            createdAt: CloudDate.timestamp(from: row.created_at) ?? date,
            updatedAt: CloudDate.timestamp(from: row.updated_at) ?? date
        )
    }

    static func custom(from row: CustomExerciseRow) -> ExerciseDefinition {
        ExerciseDefinition(
            id: "custom-\(row.id)",
            nameEN: row.name_en,
            nameZH: row.name_zh,
            aliases: row.aliases,
            muscleGroup: MuscleGroup(rawValue: row.muscle_group) ?? .fullBody,
            equipment: Equipment(rawValue: row.equipment) ?? .other,
            loadType: ExerciseLoadType(rawValue: row.load_type) ?? .unknown,
            popularity: row.popularity,
            isCustom: true
        )
    }

    // MARK: - Helpers

    /// The local custom-exercise id is `custom-<uuid>`; the cloud PK is that
    /// bare uuid. Strip on the way out, re-attach on the way in.
    static func strippedCustomId(_ id: String) -> String {
        id.hasPrefix("custom-") ? String(id.dropFirst("custom-".count)) : id
    }

    /// A synthetic empty plan for a user with nothing in the cloud yet. Given a
    /// stable UUID so the first added day has a real plan to hang off of.
    static func emptyPlan() -> TrainingPlan {
        TrainingPlan(
            id: UUID().uuidString,
            weekStartDate: CloudDate.dayString(from: startOfWeek(for: Date())),
            goalSummary: nil,
            coachSummary: "",
            days: []
        )
    }

    static func startOfWeek(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? date
    }
}
