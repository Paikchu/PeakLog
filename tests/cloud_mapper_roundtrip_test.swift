import Foundation

// Logic test: LocalDataSnapshot → push rows → assembled snapshot preserves the
// training-relevant fields. Compile with the model + cloud sources:
//   swiftc -parse-as-library \
//     PeakLog/Models/UserProfile.swift PeakLog/Models/WorkoutModels.swift \
//     PeakLog/Models/TrainingPlanModels.swift PeakLog/Models/ExerciseLibraryModels.swift \
//     PeakLog/Models/GoalSpec.swift PeakLog/Models/PlanEditEvent.swift PeakLog/Models/JSONValue.swift \
//     PeakLog/Localization/AppLanguage.swift PeakLog/Support/WorkoutDateFormatter.swift \
//     PeakLog/Services/Cloud/LocalDataSnapshot.swift PeakLog/Services/Cloud/CloudRows.swift \
//     PeakLog/Services/Cloud/CloudMapper.swift tests/cloud_mapper_roundtrip_test.swift -o /tmp/cm && /tmp/cm

@main
struct CloudMapperRoundtripTest {
    static func main() throws {
        let userId = "11111111-1111-1111-1111-111111111111"

        let planSet = TrainingPlanSet(id: "22222222-0000-0000-0000-000000000001", setIndex: 1,
            targetWeight: 62.5, targetWeightUnit: .kg, targetReps: 8, completedAt: nil, linkedExerciseSetId: nil)
        let planExercise = TrainingPlanExercise(id: "33333333-0000-0000-0000-000000000001", orderIndex: 0,
            exerciseName: "Back Squat", exerciseId: "back_squat", exerciseLoadType: .weighted,
            progressionMode: "double_progression", notes: "brace", previousPerformanceSummary: nil,
            aiSuggestion: nil, sets: [planSet])
        let cardioPlanExercise = TrainingPlanExercise(
            id: "33333333-0000-0000-0000-000000000002",
            orderIndex: 1,
            exerciseName: "Cycling",
            exerciseId: nil,
            exerciseLoadType: .unknown,
            progressionMode: "maintain",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: [],
            itemType: .cardio,
            cardioActivityType: .cycling,
            targetDurationMinutes: 35,
            targetDistanceKm: 12,
            targetRPE: 6
        )
        let planDay = TrainingPlanDay(id: "44444444-0000-0000-0000-000000000001", planDate: "2026-07-08",
            dayIndex: 0, title: "Lower A", focus: "quads", status: "planned", exercises: [planExercise, cardioPlanExercise])
        let plan = TrainingPlan(id: "55555555-0000-0000-0000-000000000001", weekStartDate: "2026-07-06",
            goalSummary: "get stronger", coachSummary: "4 days", days: [planDay])

        let set = ExerciseSet(id: "66666666-0000-0000-0000-000000000001", setIndex: 1, weight: 120,
            weightUnit: .kg, reps: 5, rpe: 8)
        let exercise = Exercise(id: "77777777-0000-0000-0000-000000000001", name: "Deadlift",
            exerciseId: "deadlift", exerciseLoadType: .weighted, sets: [set])
        let session = WorkoutSession(id: "88888888-0000-0000-0000-000000000001", userId: userId,
            date: WorkoutDateFormatter().date(from: "2026-07-07")!, durationMinutes: 60, label: "Pull",
            exercises: [exercise], createdAt: Date(timeIntervalSince1970: 1_783_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_783_000_500))

        let running = RunningWorkoutRecord(id: "99999999-0000-0000-0000-000000000001", userId: userId,
            workoutDate: WorkoutDateFormatter().date(from: "2026-07-05")!, activityType: .cycling, durationMinutes: 30,
            distanceKm: 5.2, rpe: 6, source: .manual, createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            updatedAt: Date(timeIntervalSince1970: 1_782_900_000))

        let custom = ExerciseDefinition(id: "custom-aaaaaaaa-0000-0000-0000-000000000001",
            nameEN: "Meadows Row", nameZH: "梅式划船", aliases: ["meadow"], muscleGroup: .back,
            equipment: .barbell, loadType: .weighted, popularity: 10, isCustom: true)

        let profile = UserProfile(id: userId, displayName: "Tester", avatarURL: nil,
            membershipLevel: .free,
            stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: 0, prCount: 0),
            preferences: UserPreferences(notificationsEnabled: true, darkModeEnabled: false,
                weightUnit: .kg, timezone: "Asia/Shanghai", language: AppLanguage.simplifiedChinese),
            fitnessGoalSummary: "get stronger", exercisePRs: [])

        let goalSpec = GoalSpec(objective: .strength, daysPerWeek: 4, sessionMinutes: 60,
            equipment: [.barbell], focusAreas: [.chest], experience: .intermediate, note: "phase1 test")
        let editEvent = PlanEditEvent(id: "bbbbbbbb-0000-0000-0000-000000000001", userId: userId,
            planId: plan.id, planDayId: planDay.id, planDate: planDay.planDate,
            eventType: .setTargetUpdated, exerciseName: "Back Squat", exerciseId: "back_squat",
            payload: .object(["note": .string("test")]), source: .user, clientSeq: 1,
            occurredAt: Date(timeIntervalSince1970: 1_783_000_100))

        let original = LocalDataSnapshot(profile: profile, activePlan: plan,
            strengthSessions: [session], runningRecords: [running], customExercises: [custom],
            goalSpec: goalSpec, pendingEditEvents: [editEvent])

        // Push → rows.
        let bundle = try CloudMapper.pushBundle(from: original, userId: userId)

        // Custom id must lose its "custom-" prefix on the wire.
        precondition(bundle.customExercises[0].id == "aaaaaaaa-0000-0000-0000-000000000001",
            "custom id should be stripped for cloud")
        precondition(bundle.exercises[0].exercise_load_type == "weighted", "load type lost")
        precondition(bundle.planSets[0].target_weight == 62.5, "plan target weight lost")
        precondition(bundle.planExercises[1].item_type == "cardio", "cardio item type lost")
        precondition(bundle.planExercises[1].cardio_activity_type == "cycling", "cardio activity type lost")
        precondition(bundle.planExercises[1].target_duration_minutes == 35, "cardio duration lost")
        precondition(bundle.running[0].activity_type == "cycling", "record activity type lost")
        precondition(bundle.running[0].rpe == 6, "record RPE lost")
        precondition(bundle.goalSpec?.objective == "strength", "goal spec objective lost")
        precondition(bundle.editEvents.count == 1 && bundle.editEvents[0].event_type == "set_target_updated",
            "edit event lost in push bundle")

        // Rows → assembled snapshot.
        let back = CloudMapper.assembleSnapshot(userId: userId,
            profileRow: bundle.profile, preferencesRow: bundle.preferences,
            goalSpecRow: bundle.goalSpec,
            customRows: bundle.customExercises, sessionRows: bundle.sessions,
            exerciseRows: bundle.exercises, setRows: bundle.exerciseSets,
            runningRows: bundle.running, planRows: bundle.plans, planDayRows: bundle.planDays,
            planExerciseRows: bundle.planExercises, planSetRows: bundle.planSets)

        precondition(back.goalSpec?.objective == .strength, "goal spec must round-trip through a pull")
        precondition(back.pendingEditEvents.isEmpty, "a pulled snapshot must never carry local outbox events (EV1)")

        // Assert the training-relevant fields survived the round-trip.
        precondition(back.activePlan.id == plan.id, "plan id")
        precondition(back.activePlan.days.first?.exercises.first?.exerciseName == "Back Squat", "plan exercise name")
        precondition(back.activePlan.days.first?.exercises.first?.sets.first?.targetWeight == 62.5, "plan target weight")
        precondition(back.activePlan.days.first?.exercises.first?.exerciseId == "back_squat", "plan slug")
        precondition(back.activePlan.days.first?.exercises.last?.cardioActivityType == .cycling, "cardio plan type")
        precondition(back.activePlan.days.first?.exercises.last?.targetDistanceKm == 12, "cardio plan distance")
        precondition(back.strengthSessions.first?.exercises.first?.name == "Deadlift", "session exercise")
        precondition(back.strengthSessions.first?.exercises.first?.sets.first?.weight == 120, "logged weight")
        precondition(back.strengthSessions.first?.durationMinutes == 60, "duration minutes")
        precondition(back.runningRecords.first?.distanceKm == 5.2, "running distance")
        precondition(back.runningRecords.first?.activityType == .cycling, "cardio record type")
        precondition(back.runningRecords.first?.rpe == 6, "cardio record RPE")
        precondition(back.customExercises.first?.id == "custom-aaaaaaaa-0000-0000-0000-000000000001", "custom id re-attached")
        precondition(back.customExercises.first?.nameZH == "梅式划船", "custom zh name")
        precondition(back.profile.fitnessGoalSummary == "get stronger", "goal summary")
        precondition(back.profile.preferences.language == .simplifiedChinese, "language")
        precondition(back.profile.preferences.timezone == "Asia/Shanghai", "timezone")

        // Cloud rows with seconds that aren't a multiple of 60 must round, not truncate (issue #16).
        var oddSeconds = bundle.sessions[0]
        oddSeconds.duration_seconds = 90
        let rounded = CloudMapper.assembleSnapshot(userId: userId,
            profileRow: bundle.profile, preferencesRow: bundle.preferences,
            goalSpecRow: bundle.goalSpec,
            customRows: bundle.customExercises, sessionRows: [oddSeconds],
            exerciseRows: bundle.exercises, setRows: bundle.exerciseSets,
            runningRows: bundle.running, planRows: bundle.plans, planDayRows: bundle.planDays,
            planExerciseRows: bundle.planExercises, planSetRows: bundle.planSets)
        precondition(rounded.strengthSessions.first?.durationMinutes == 2,
            "90s should round to 2 minutes, not truncate to 1")

        oddSeconds.duration_seconds = 30
        let short = CloudMapper.assembleSnapshot(userId: userId,
            profileRow: bundle.profile, preferencesRow: bundle.preferences,
            goalSpecRow: bundle.goalSpec,
            customRows: bundle.customExercises, sessionRows: [oddSeconds],
            exerciseRows: bundle.exercises, setRows: bundle.exerciseSets,
            runningRows: bundle.running, planRows: bundle.plans, planDayRows: bundle.planDays,
            planExerciseRows: bundle.planExercises, planSetRows: bundle.planSets)
        precondition(short.strengthSessions.first?.durationMinutes == 1,
            "30s should round to 1 minute, not truncate to 0")

        print("cloud_mapper_roundtrip_test passed")
    }
}
