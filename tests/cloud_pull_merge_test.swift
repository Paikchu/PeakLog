import Foundation

// Logic test for `LocalAppDatabase.mergeFromCloud` — the Issue #1 fix that
// stops a login pull from blindly overwriting offline user data.
//
// Coverage:
//   1. offline UUID session/run/custom survive merge; seed rows dropped;
//      cloud rows present; plan/profile/goalSpec cloud-wins.
//   2. same-id collisions resolve by updatedAt (local-wins when newer;
//      cloud-wins when newer).
//   3. seed plan (local-plan) replaced by cloud plan.
//   4. offline plan-set completion markers preserved when plan ids match and
//      the completion is backed by a real logged set (b637e5e invariant),
//      even if that session has not yet synced to the cloud; no backfill when
//      plan ids differ.
//   5. offline cardio completion markers survive when the plan id matches and
//      their linked cardio record is still present.
//   6. pendingEditEvents untouched (EV1).
//   7. mergeFromCloud does not fire onChange (no pull→push echo).
//
// Compile with:
//   swiftc -parse-as-library \
//     PeakLog/Models/*.swift PeakLog/Localization/AppLanguage.swift \
//     PeakLog/Support/WorkoutDateFormatter.swift \
//     PeakLog/Services/SupabaseConfig.swift \
//     PeakLog/Services/Auth/*.swift \
//     PeakLog/Services/ProfileService.swift PeakLog/Services/WorkoutService.swift \
//     PeakLog/Services/TrainingPlanService.swift PeakLog/Services/ExerciseLibraryService.swift \
//     PeakLog/Services/ExerciseRecommendationEngine.swift PeakLog/Services/SetDefaultsProvider.swift \
//     PeakLog/Services/LocalAppDatabase.swift \
//     PeakLog/Services/Cloud/LocalDataSnapshot.swift \
//     tests/cloud_pull_merge_test.swift -o /tmp/cpm && /tmp/cpm

@main
struct CloudPullMergeTest {
    static func main() async {
        await testOfflineRecordsSurviveAndSeedDropped()
        await testUpdatedAtLastWriteWins()
        await testSeedPlanReplacedByCloudPlan()
        await testPlanCompletionPreservedWhenSamePlanId()
        await testCardioCompletionPreservedWhenSamePlanId()
        await testNoCompletionBackfillWhenPlanIdsDiffer()
        await testPendingEditEventsUntouched()
        await testMergeDoesNotFireOnChange()
        print("cloud_pull_merge_test passed")
    }

    static func testCardioCompletionPreservedWhenSamePlanId() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        let profile = await db.fetchProfile()
        let completedAt = Date(timeIntervalSince1970: 1_783_000_000)
        let linkedRecordId = UUID().uuidString

        let localExercise = TrainingPlanExercise(
            id: "cardio-1", orderIndex: 0, exerciseName: "Cycling",
            exerciseLoadType: .unknown, progressionMode: "manual", notes: nil,
            previousPerformanceSummary: nil, aiSuggestion: nil, sets: [],
            itemType: .cardio, cardioActivityType: .cycling,
            targetDurationMinutes: 30, targetDistanceKm: 10, targetRPE: 6,
            cardioCompletedAt: completedAt, linkedCardioWorkoutId: linkedRecordId)
        let localPlan = TrainingPlan(
            id: "plan-cardio", weekStartDate: "2026-07-06",
            goalSummary: "local", coachSummary: "local", days: [TrainingPlanDay(
                id: "day-cardio", planDate: "2026-07-08", dayIndex: 1,
                title: "Local Cardio", focus: nil, status: "planned", exercises: [localExercise])])
        let localRecord = CardioWorkoutRecord(
            id: linkedRecordId, userId: profile.id, workoutDate: Date(),
            activityType: .cycling, durationMinutes: 32, distanceKm: 11,
            rpe: 7, source: .manual, createdAt: completedAt, updatedAt: completedAt)
        await db.replaceAll(profile: profile, activePlan: localPlan,
            strengthSessions: [], runningRecords: [localRecord], customExercises: [], goalSpec: nil)

        let cloudExercise = TrainingPlanExercise(
            id: "cardio-1", orderIndex: 0, exerciseName: "Cycling",
            exerciseLoadType: .unknown, progressionMode: "manual", notes: nil,
            previousPerformanceSummary: nil, aiSuggestion: nil, sets: [],
            itemType: .cardio, cardioActivityType: .cycling,
            targetDurationMinutes: 30, targetDistanceKm: 10, targetRPE: 6)
        let cloudPlan = TrainingPlan(
            id: "plan-cardio", weekStartDate: "2026-07-06",
            goalSummary: "cloud", coachSummary: "cloud", days: [TrainingPlanDay(
                id: "day-cardio", planDate: "2026-07-08", dayIndex: 1,
                title: "Cloud Cardio", focus: nil, status: "planned", exercises: [cloudExercise])])

        await db.mergeFromCloud(profile: profile, activePlan: cloudPlan,
            strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        let snapshot = await db.snapshot()
        let merged = snapshot.activePlan.days[0].exercises[0]
        precondition(merged.cardioCompletedAt == completedAt,
            "offline cardio completion timestamp must survive cloud pull")
        precondition(merged.linkedCardioWorkoutId == linkedRecordId,
            "offline cardio record link must survive cloud pull")
        precondition(snapshot.runningRecords.contains { $0.id == linkedRecordId },
            "offline linked cardio record must survive cloud pull")
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-merge-test-\(UUID().uuidString).json")
    }

    static func cloudProfile(id: String = "cloud-user") -> UserProfile {
        UserProfile(
            id: id,
            displayName: "Cloud User",
            avatarURL: nil,
            membershipLevel: .free,
            stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: 0, prCount: 0),
            preferences: UserPreferences(
                notificationsEnabled: true, darkModeEnabled: false,
                weightUnit: .kg, timezone: "UTC", language: .english
            ),
            fitnessGoalSummary: "cloud goal",
            exercisePRs: []
        )
    }

    static func cloudGoalSpec() -> GoalSpec {
        GoalSpec(objective: .strength, daysPerWeek: 3, sessionMinutes: 45,
                 equipment: [], focusAreas: [], experience: .intermediate, note: "cloud")
    }

    static func draft(title: String) -> StrengthSessionDraft {
        StrengthSessionDraft(
            title: title,
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Row", exerciseId: nil, exerciseLoadType: .weighted,
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(
                        weight: 50, weightUnit: .kg, reps: 10, rpe: nil)]
                )
            ]
        )
    }

    // 1. Offline records survive; seed rows dropped; cloud rows present;
    //    plan/profile/goalSpec cloud-wins.
    static func testOfflineRecordsSurviveAndSeedDropped() async {
        let db = LocalAppDatabase(fileURL: tempURL())

        // Seed state has seed-session-1, seed-run-1, local-plan, local-user.
        let offlineRun = try! await db.createRunningRecord(
            workoutDate: Date(), durationMinutes: 25, distanceKm: 3.0, source: .manual)
        let offlineSession = try! await db.createStrengthSession(draft(title: "Offline Pull"))
        let offlineCustom = try! await db.addCustomExercise(
            name: "Meadows Row", muscleGroup: .back, loadType: .weighted)

        let cloudSession = WorkoutSession(
            id: UUID().uuidString, userId: "cloud-user", date: Date(),
            durationMinutes: nil, label: "Cloud Session", exercises: [],
            createdAt: Date(), updatedAt: Date())
        let cloudRun = RunningWorkoutRecord(
            id: UUID().uuidString, userId: "cloud-user", workoutDate: Date(),
            durationMinutes: 20, distanceKm: 2.0, source: .manual,
            createdAt: Date(), updatedAt: Date())
        let cloudCustom = ExerciseDefinition(
            id: "custom-\(UUID().uuidString)", nameEN: "Cloud Curl", nameZH: "云弯举",
            aliases: [], muscleGroup: .arms, equipment: .dumbbell, loadType: .weighted,
            popularity: 10, isCustom: true)
        let cloudPlan = TrainingPlan(
            id: "cloud-plan-id", weekStartDate: "2026-07-06",
            goalSummary: "cloud plan goal", coachSummary: "cloud coach", days: [])

        await db.mergeFromCloud(
            profile: cloudProfile(), activePlan: cloudPlan,
            strengthSessions: [cloudSession], runningRecords: [cloudRun],
            customExercises: [cloudCustom], goalSpec: cloudGoalSpec())

        let snap = await db.snapshot()
        let sessionIds = Set(snap.strengthSessions.map(\.id))
        precondition(sessionIds.contains(offlineSession.id), "offline session must survive merge")
        precondition(sessionIds.contains(cloudSession.id), "cloud session must be present")
        precondition(!sessionIds.contains("seed-session-1"), "seed session must be dropped")
        precondition(snap.strengthSessions.count == 2,
            "expected 2 sessions (offline + cloud), got \(snap.strengthSessions.count)")

        let runIds = Set(snap.runningRecords.map(\.id))
        precondition(runIds.contains(offlineRun.id), "offline run must survive merge")
        precondition(runIds.contains(cloudRun.id), "cloud run must be present")
        precondition(!runIds.contains("seed-run-1"), "seed run must be dropped")
        precondition(snap.runningRecords.count == 2,
            "expected 2 runs, got \(snap.runningRecords.count)")

        let customIds = Set(snap.customExercises.map(\.id))
        precondition(customIds.contains(offlineCustom.id), "offline custom must survive merge")
        precondition(customIds.contains(cloudCustom.id), "cloud custom must be present")
        precondition(snap.customExercises.count == 2,
            "expected 2 customs, got \(snap.customExercises.count)")

        precondition(snap.activePlan.id == "cloud-plan-id", "cloud plan must win (seed plan dropped)")
        precondition(snap.profile.id == "cloud-user", "cloud profile must win")
        precondition(snap.profile.fitnessGoalSummary == "cloud goal", "cloud profile fields win")
        precondition(snap.goalSpec == cloudGoalSpec(), "cloud goalSpec must win")
    }

    // 2. updatedAt LWW: local wins when newer; cloud wins when newer.
    static func testUpdatedAtLastWriteWins() async {
        // Local newer → local wins.
        let dbLocal = LocalAppDatabase(fileURL: tempURL())
        let localSession = try! await dbLocal.createStrengthSession(draft(title: "Local Wins"))
        let olderCloud = WorkoutSession(
            id: localSession.id, userId: "cloud-user", date: localSession.date,
            durationMinutes: 99, label: "Cloud Should Lose", exercises: localSession.exercises,
            createdAt: localSession.createdAt, updatedAt: localSession.updatedAt.addingTimeInterval(-3600))
        await dbLocal.mergeFromCloud(
            profile: cloudProfile(), activePlan: TrainingPlan(
                id: "p", weekStartDate: "2026-07-06", goalSummary: nil, coachSummary: "c", days: []),
            strengthSessions: [olderCloud], runningRecords: [], customExercises: [], goalSpec: nil)
        let mergedLocal = await dbLocal.snapshot().strengthSessions.first { $0.id == localSession.id }
        precondition(mergedLocal?.label == "Local Wins",
            "local must win when its updatedAt is newer, got \(mergedLocal?.label ?? "nil")")
        precondition(mergedLocal?.durationMinutes == nil,
            "local session fields must be preserved (durationMinutes nil), got \(mergedLocal?.durationMinutes as Any)")

        // Cloud newer → cloud wins.
        let dbCloud = LocalAppDatabase(fileURL: tempURL())
        let localSession2 = try! await dbCloud.createStrengthSession(draft(title: "Local Loses"))
        let newerCloud = WorkoutSession(
            id: localSession2.id, userId: "cloud-user", date: localSession2.date,
            durationMinutes: 77, label: "Cloud Wins", exercises: localSession2.exercises,
            createdAt: localSession2.createdAt, updatedAt: localSession2.updatedAt.addingTimeInterval(3600))
        await dbCloud.mergeFromCloud(
            profile: cloudProfile(), activePlan: TrainingPlan(
                id: "p", weekStartDate: "2026-07-06", goalSummary: nil, coachSummary: "c", days: []),
            strengthSessions: [newerCloud], runningRecords: [], customExercises: [], goalSpec: nil)
        let mergedCloud = await dbCloud.snapshot().strengthSessions.first { $0.id == localSession2.id }
        precondition(mergedCloud?.label == "Cloud Wins",
            "cloud must win when its updatedAt is newer, got \(mergedCloud?.label ?? "nil")")
        precondition(mergedCloud?.durationMinutes == 77,
            "cloud session fields must be preserved, got \(mergedCloud?.durationMinutes as Any)")
    }

    // 3. Seed plan (local-plan) is replaced by the cloud plan (different id).
    static func testSeedPlanReplacedByCloudPlan() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        let beforePlan = await db.activePlan()
        precondition(beforePlan?.id == "local-plan", "seed plan should be local-plan")

        let cloudPlan = TrainingPlan(
            id: "cloud-plan-id", weekStartDate: "2026-07-06",
            goalSummary: "cloud", coachSummary: "c", days: [])
        await db.mergeFromCloud(
            profile: cloudProfile(), activePlan: cloudPlan,
            strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        let after = await db.snapshot()
        precondition(after.activePlan.id == "cloud-plan-id",
            "seed plan must be replaced by cloud plan, got \(after.activePlan.id)")
    }

    // 4. Same plan id: offline completion markers survive onto the cloud plan.
    //    A genuine offline completion is backed by a real logged set (created
    //    by `completePlannedSet` → `ensureStrengthSessionForPlanDay`), so its
    //    `linkedExerciseSetId` resolves in `strengthSessions`. We seed that
    //    backing set in LOCAL state only and deliberately do NOT hand it to
    //    `mergeFromCloud` as cloud data — proving the completion survives even
    //    when the backing workout session has not yet synced to the cloud,
    //    because `mergeRecords` retains local user-generated sessions and the
    //    completion therefore passes `sanitizePlanCompletionLinks` (b637e5e).
    static func testPlanCompletionPreservedWhenSamePlanId() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        let profile = await db.fetchProfile()

        let completedAt = Date(timeIntervalSince1970: 1_783_000_000)
        let localSet = TrainingPlanSet(
            id: "set-1", setIndex: 1, targetWeight: 60, targetWeightUnit: .kg, targetReps: 8,
            completedAt: completedAt, linkedExerciseSetId: "link-1")
        let localExercise = TrainingPlanExercise(
            id: "ex-1", orderIndex: 0, exerciseName: "Bench", exerciseId: nil,
            exerciseLoadType: .weighted, progressionMode: "manual", notes: nil,
            previousPerformanceSummary: nil, aiSuggestion: nil, sets: [localSet])
        let localDay = TrainingPlanDay(
            id: "day-1", planDate: "2026-07-08", dayIndex: 1, title: "Local Day",
            focus: nil, status: "planned", exercises: [localExercise])
        let localPlan = TrainingPlan(
            id: "plan-1", weekStartDate: "2026-07-06",
            goalSummary: "local goal", coachSummary: "local coach", days: [localDay])

        // The offline logged set that backs the completion (id matches the
        // plan set's linkedExerciseSetId). Its session id is a user-generated
        // UUID so `mergeRecords` keeps it as a local-only offline row.
        let offlineLoggedSession = WorkoutSession(
            id: UUID().uuidString, userId: "offline-user", date: Date(),
            durationMinutes: nil, label: "Offline Bench",
            exercises: [Exercise(
                id: UUID().uuidString, name: "Bench", exerciseId: nil,
                exerciseLoadType: .weighted,
                sets: [ExerciseSet(id: "link-1", setIndex: 1, weight: 60,
                    weightUnit: .kg, reps: 8, rpe: nil)])],
            createdAt: Date(), updatedAt: Date())

        // Set local state to the controlled plan via replaceAll (setup only).
        await db.replaceAll(profile: profile, activePlan: localPlan,
            strengthSessions: [offlineLoggedSession], runningRecords: [],
            customExercises: [], goalSpec: nil)

        // Cloud plan: SAME id, same set id but NOT completed; cloud structural
        // fields (goal/title) differ to prove cloud structure still wins.
        let cloudSet = TrainingPlanSet(
            id: "set-1", setIndex: 1, targetWeight: 60, targetWeightUnit: .kg, targetReps: 8,
            completedAt: nil, linkedExerciseSetId: nil)
        let cloudExercise = TrainingPlanExercise(
            id: "ex-1", orderIndex: 0, exerciseName: "Bench", exerciseId: nil,
            exerciseLoadType: .weighted, progressionMode: "manual", notes: nil,
            previousPerformanceSummary: nil, aiSuggestion: nil, sets: [cloudSet])
        let cloudDay = TrainingPlanDay(
            id: "day-1", planDate: "2026-07-08", dayIndex: 1, title: "Cloud Day",
            focus: nil, status: "planned", exercises: [cloudExercise])
        let cloudPlan = TrainingPlan(
            id: "plan-1", weekStartDate: "2026-07-06",
            goalSummary: "cloud goal", coachSummary: "cloud coach", days: [cloudDay])

        await db.mergeFromCloud(
            profile: profile, activePlan: cloudPlan,
            strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        let snap = await db.snapshot()
        precondition(snap.activePlan.id == "plan-1", "plan id unchanged (same plan)")
        precondition(snap.activePlan.goalSummary == "cloud goal", "cloud plan goal wins")
        precondition(snap.activePlan.days[0].title == "Cloud Day", "cloud day title wins")
        let mergedSet = snap.activePlan.days[0].exercises[0].sets[0]
        precondition(mergedSet.completedAt == completedAt,
            "offline completion marker must survive (completedAt), got \(mergedSet.completedAt as Any)")
        precondition(mergedSet.linkedExerciseSetId == "link-1",
            "offline completion marker must survive (linkedExerciseSetId), got \(mergedSet.linkedExerciseSetId as Any)")
    }

    // 5. Different plan id: cloud wins wholesale, no completion backfill.
    static func testNoCompletionBackfillWhenPlanIdsDiffer() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        let profile = await db.fetchProfile()

        let completedAt = Date(timeIntervalSince1970: 1_783_000_000)
        let localSet = TrainingPlanSet(
            id: "set-1", setIndex: 1, targetWeight: 60, targetWeightUnit: .kg, targetReps: 8,
            completedAt: completedAt, linkedExerciseSetId: "link-1")
        let localExercise = TrainingPlanExercise(
            id: "ex-1", orderIndex: 0, exerciseName: "Bench", exerciseId: nil,
            exerciseLoadType: .weighted, progressionMode: "manual", notes: nil,
            previousPerformanceSummary: nil, aiSuggestion: nil, sets: [localSet])
        let localDay = TrainingPlanDay(
            id: "day-1", planDate: "2026-07-08", dayIndex: 1, title: "Local Day",
            focus: nil, status: "planned", exercises: [localExercise])
        let localPlan = TrainingPlan(
            id: "plan-1", weekStartDate: "2026-07-06",
            goalSummary: "local goal", coachSummary: "local coach", days: [localDay])
        await db.replaceAll(profile: profile, activePlan: localPlan,
            strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        // Cloud plan: DIFFERENT id, set NOT completed (same set id).
        let cloudSet = TrainingPlanSet(
            id: "set-1", setIndex: 1, targetWeight: 60, targetWeightUnit: .kg, targetReps: 8,
            completedAt: nil, linkedExerciseSetId: nil)
        let cloudExercise = TrainingPlanExercise(
            id: "ex-1", orderIndex: 0, exerciseName: "Bench", exerciseId: nil,
            exerciseLoadType: .weighted, progressionMode: "manual", notes: nil,
            previousPerformanceSummary: nil, aiSuggestion: nil, sets: [cloudSet])
        let cloudDay = TrainingPlanDay(
            id: "day-1", planDate: "2026-07-08", dayIndex: 1, title: "Cloud Day",
            focus: nil, status: "planned", exercises: [cloudExercise])
        let otherCloudPlan = TrainingPlan(
            id: "plan-2", weekStartDate: "2026-07-06",
            goalSummary: "other", coachSummary: "c", days: [cloudDay])

        await db.mergeFromCloud(
            profile: profile, activePlan: otherCloudPlan,
            strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        let snap = await db.snapshot()
        precondition(snap.activePlan.id == "plan-2",
            "cloud plan wins when id differs (local/seed plan replaced), got \(snap.activePlan.id)")
        let mergedSet = snap.activePlan.days[0].exercises[0].sets[0]
        precondition(mergedSet.completedAt == nil,
            "no completion backfill when plan ids differ, got \(mergedSet.completedAt as Any)")
        precondition(mergedSet.linkedExerciseSetId == nil,
            "no linkedId backfill when plan ids differ, got \(mergedSet.linkedExerciseSetId as Any)")
    }

    // 6. pendingEditEvents untouched by merge (EV1).
    static func testPendingEditEventsUntouched() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        await db.armCloudSync(userId: "user-a") {}
        _ = try! await db.addPlannedExercises([
            PlanExerciseDraft(exerciseName: "OHP", exerciseId: nil, isBodyweight: false,
                sets: [.init(targetWeight: 40, targetWeightUnit: .kg, targetReps: 8)])
        ])
        let before = await db.snapshot().pendingEditEvents
        precondition(!before.isEmpty, "setup should have produced at least one event")

        let profile = await db.fetchProfile()
        let plan = await db.activePlan()!
        await db.mergeFromCloud(profile: profile, activePlan: plan,
            strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        let after = await db.snapshot().pendingEditEvents
        precondition(after.map(\.id) == before.map(\.id),
            "mergeFromCloud must not touch pendingEditEvents (EV1)")
    }

    // 7. mergeFromCloud does not fire onChange (pull must not echo as push).
    static func testMergeDoesNotFireOnChange() async {
        final class FireFlag: @unchecked Sendable { var fired = false }
        let flag = FireFlag()

        let db = LocalAppDatabase(fileURL: tempURL())
        await db.armCloudSync(userId: "user-a") { flag.fired = true }

        let profile = await db.fetchProfile()
        let plan = await db.activePlan()!
        await db.mergeFromCloud(profile: profile, activePlan: plan,
            strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        precondition(!flag.fired,
            "mergeFromCloud must not fire onChange (pull must not echo as push)")
    }
}
