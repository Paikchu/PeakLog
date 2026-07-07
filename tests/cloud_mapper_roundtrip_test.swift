import Foundation

// Logic test: LocalDataSnapshot → push rows → assembled snapshot preserves the
// training-relevant fields. Compile with the model + cloud sources:
//   swiftc -parse-as-library \
//     PeakLog/Models/UserProfile.swift PeakLog/Models/WorkoutModels.swift \
//     PeakLog/Models/TrainingPlanModels.swift PeakLog/Models/ExerciseLibraryModels.swift \
//     PeakLog/Localization/AppLanguage.swift PeakLog/Support/WorkoutDateFormatter.swift \
//     PeakLog/Services/Cloud/LocalDataSnapshot.swift PeakLog/Services/Cloud/CloudRows.swift \
//     PeakLog/Services/Cloud/CloudMapper.swift tests/cloud_mapper_roundtrip_test.swift -o /tmp/cm && /tmp/cm

@main
struct CloudMapperRoundtripTest {
    static func main() {
        let userId = "11111111-1111-1111-1111-111111111111"

        let planSet = TrainingPlanSet(id: "22222222-0000-0000-0000-000000000001", setIndex: 1,
            targetWeight: 62.5, targetWeightUnit: .kg, targetReps: 8, completedAt: nil, linkedExerciseSetId: nil)
        let planExercise = TrainingPlanExercise(id: "33333333-0000-0000-0000-000000000001", orderIndex: 0,
            exerciseName: "Back Squat", exerciseId: "back_squat", exerciseLoadType: .weighted,
            progressionMode: "double_progression", notes: "brace", previousPerformanceSummary: nil,
            aiSuggestion: nil, sets: [planSet])
        let planDay = TrainingPlanDay(id: "44444444-0000-0000-0000-000000000001", planDate: "2026-07-08",
            dayIndex: 0, title: "Lower A", focus: "quads", status: "planned", exercises: [planExercise])
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
            workoutDate: WorkoutDateFormatter().date(from: "2026-07-05")!, durationMinutes: 30,
            distanceKm: 5.2, source: .manual, createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            updatedAt: Date(timeIntervalSince1970: 1_782_900_000))

        let custom = ExerciseDefinition(id: "custom-aaaaaaaa-0000-0000-0000-000000000001",
            nameEN: "Meadows Row", nameZH: "梅式划船", aliases: ["meadow"], muscleGroup: .back,
            equipment: .barbell, loadType: .weighted, popularity: 10, isCustom: true)

        let profile = UserProfile(id: userId, displayName: "Tester", avatarURL: nil,
            membershipLevel: .free,
            stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: 0, prCount: 0),
            preferences: UserPreferences(notificationsEnabled: true, darkModeEnabled: false,
                weightUnit: .kg, timezone: "Asia/Shanghai", language: .simplifiedChinese),
            fitnessGoalSummary: "get stronger", exercisePRs: [])

        let original = LocalDataSnapshot(profile: profile, activePlan: plan,
            strengthSessions: [session], runningRecords: [running], customExercises: [custom])

        // Push → rows.
        let bundle = CloudMapper.pushBundle(from: original, userId: userId)

        // Custom id must lose its "custom-" prefix on the wire.
        precondition(bundle.customExercises[0].id == "aaaaaaaa-0000-0000-0000-000000000001",
            "custom id should be stripped for cloud")
        precondition(bundle.exercises[0].exercise_load_type == "weighted", "load type lost")
        precondition(bundle.planSets[0].target_weight == 62.5, "plan target weight lost")

        // Rows → assembled snapshot.
        let back = CloudMapper.assembleSnapshot(userId: userId,
            profileRow: bundle.profile, preferencesRow: bundle.preferences,
            customRows: bundle.customExercises, sessionRows: bundle.sessions,
            exerciseRows: bundle.exercises, setRows: bundle.exerciseSets,
            runningRows: bundle.running, planRows: bundle.plans, planDayRows: bundle.planDays,
            planExerciseRows: bundle.planExercises, planSetRows: bundle.planSets)

        // Assert the training-relevant fields survived the round-trip.
        precondition(back.activePlan.id == plan.id, "plan id")
        precondition(back.activePlan.days.first?.exercises.first?.exerciseName == "Back Squat", "plan exercise name")
        precondition(back.activePlan.days.first?.exercises.first?.sets.first?.targetWeight == 62.5, "plan target weight")
        precondition(back.activePlan.days.first?.exercises.first?.exerciseId == "back_squat", "plan slug")
        precondition(back.strengthSessions.first?.exercises.first?.name == "Deadlift", "session exercise")
        precondition(back.strengthSessions.first?.exercises.first?.sets.first?.weight == 120, "logged weight")
        precondition(back.strengthSessions.first?.durationMinutes == 60, "duration minutes")
        precondition(back.runningRecords.first?.distanceKm == 5.2, "running distance")
        precondition(back.customExercises.first?.id == "custom-aaaaaaaa-0000-0000-0000-000000000001", "custom id re-attached")
        precondition(back.customExercises.first?.nameZH == "梅式划船", "custom zh name")
        precondition(back.profile.fitnessGoalSummary == "get stronger", "goal summary")
        precondition(back.profile.preferences.language == .simplifiedChinese, "language")
        precondition(back.profile.preferences.timezone == "Asia/Shanghai", "timezone")

        print("cloud_mapper_roundtrip_test passed")
    }
}
