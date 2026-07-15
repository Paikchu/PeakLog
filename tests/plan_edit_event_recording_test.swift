import Foundation

// Logic test: every plan-structure mutation records the right PlanEditEvent;
// completing a set does not; a pull (replaceAll) never wipes pending events
// (EV1); arming under a different account discards the previous account's
// leftover events (EV9). Compile with:
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
//     tests/plan_edit_event_recording_test.swift -o /tmp/pe && /tmp/pe

@main
struct PlanEditEventRecordingTest {
    static func main() async {
        await testMutationsRecordExpectedEvents()
        await testCardioAddEventCarriesTargets()
        await testCompletePlannedSetDoesNotRecordEvent()
        await testReplaceAllPreservesPendingEvents()
        await testArmCloudSyncDiscardsMismatchedAccountEvents()
        print("plan_edit_event_recording_test passed")
    }

    static func testCardioAddEventCarriesTargets() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        await db.armCloudSync(userId: "user-a") {}

        let draft = try! PlanExerciseDraft.cardio(
            activityType: .cycling,
            targetDurationMinutes: 40,
            targetDistanceKm: 15
        )
        _ = try! await db.addPlannedExercises([draft])

        let events = await db.snapshot().pendingEditEvents
        guard let event = events.last,
              event.eventType == .exerciseAdded,
              case .object(let payload) = event.payload,
              case .string("cardio")? = payload["itemType"],
              case .string("cycling")? = payload["cardioActivityType"],
              case .number(40)? = payload["targetDurationMinutes"],
              case .number(15)? = payload["targetDistanceKm"],
              payload["targetRPE"] == nil
        else {
            fatalError("cardio exercise_added payload missing activity or targets")
        }
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-events-test-\(UUID().uuidString).json")
    }

    static func testMutationsRecordExpectedEvents() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        await db.armCloudSync(userId: "user-a") {}

        let day = try! await db.addPlannedExercises([
            PlanExerciseDraft(exerciseName: "Bench Press", exerciseId: "bench", isBodyweight: false,
                sets: [.init(targetWeight: 60, targetWeightUnit: .kg, targetReps: 8)])
        ])
        let exercise = day.exercises[0]

        let newSet = try! await db.addPlannedSet(planExerciseId: exercise.id, targetWeight: 62.5, targetWeightUnit: .kg, targetReps: 6)
        _ = try! await db.updatePlannedSet(planSetId: newSet.id, targetWeight: 65, targetWeightUnit: .kg, targetReps: 5)
        try! await db.deletePlannedSet(planSetId: newSet.id)

        let day2 = try! await db.addPlannedExercises([
            PlanExerciseDraft(exerciseName: "Squat", exerciseId: "squat", isBodyweight: false,
                sets: [.init(targetWeight: 80, targetWeightUnit: .kg, targetReps: 5)])
        ])
        let orderedIds = day2.exercises.map(\.id)
        _ = try! await db.reorderPlannedExercises(orderedExerciseIds: Array(orderedIds.reversed()))

        try! await db.deletePlannedExercise(planExerciseId: exercise.id)
        _ = try! await db.updateFitnessGoalSummary("get shredded")
        _ = try! await db.updateGoalSpec(GoalSpec(
            objective: .strength, daysPerWeek: 4, sessionMinutes: 60,
            equipment: [], focusAreas: [], experience: .beginner, note: nil
        ))

        let events = await db.snapshot().pendingEditEvents
        let types = events.map(\.eventType)
        precondition(types.filter { $0 == .exerciseAdded }.count == 2, "expected 2 exercise_added events, got \(types)")
        precondition(types.contains(.setAdded), "missing set_added")
        precondition(types.contains(.setTargetUpdated), "missing set_target_updated")
        precondition(types.contains(.setRemoved), "missing set_removed")
        precondition(types.contains(.exercisesReordered), "missing exercises_reordered")
        precondition(types.contains(.exerciseRemoved), "missing exercise_removed")
        precondition(types.filter { $0 == .goalChanged }.count == 2, "expected 2 goal_changed events (free-text + structured), got \(types)")

        let seqs = events.map(\.clientSeq)
        precondition(seqs == seqs.sorted(), "client_seq must be monotonically increasing")
        precondition(Set(seqs).count == seqs.count, "client_seq values must be unique")
        precondition(events.allSatisfy { $0.userId == "user-a" }, "all events must carry the armed userId")

        // set_target_updated must carry both before and after snapshots.
        guard let updated = events.first(where: { $0.eventType == .setTargetUpdated }),
              case .object(let payload) = updated.payload,
              case .object(let before)? = payload["before"],
              case .object(let after)? = payload["after"],
              case .number(let beforeWeight)? = before["targetWeight"],
              case .number(let afterWeight)? = after["targetWeight"]
        else {
            fatalError("set_target_updated payload missing before/after weight")
        }
        precondition(beforeWeight == 62.5 && afterWeight == 65, "before/after weights wrong: \(beforeWeight) -> \(afterWeight)")

        print("  mutation coverage OK (\(events.count) events)")
    }

    static func testCompletePlannedSetDoesNotRecordEvent() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        await db.armCloudSync(userId: "user-a") {}

        let day = try! await db.addPlannedExercises([
            PlanExerciseDraft(exerciseName: "Deadlift", exerciseId: "deadlift", isBodyweight: false,
                sets: [.init(targetWeight: 100, targetWeightUnit: .kg, targetReps: 5)])
        ])
        let beforeCount = await db.snapshot().pendingEditEvents.count

        let planSetId = day.exercises[0].sets[0].id
        _ = try! await db.completePlannedSet(planSetId: planSetId, actualWeight: 100, actualWeightUnit: .kg, actualReps: 5)

        let afterCount = await db.snapshot().pendingEditEvents.count
        precondition(afterCount == beforeCount, "completing a planned set must not record an edit event")
    }

    static func testReplaceAllPreservesPendingEvents() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        await db.armCloudSync(userId: "user-a") {}
        _ = try! await db.addPlannedExercises([
            PlanExerciseDraft(exerciseName: "Overhead Press", exerciseId: nil, isBodyweight: false,
                sets: [.init(targetWeight: 40, targetWeightUnit: .kg, targetReps: 8)])
        ])
        let before = await db.snapshot().pendingEditEvents
        precondition(!before.isEmpty, "setup should have produced at least one event")

        let profile = await db.fetchProfile()
        let plan = await db.activePlan()!
        await db.replaceAll(profile: profile, activePlan: plan, strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)

        let after = await db.snapshot().pendingEditEvents
        precondition(after.map(\.id) == before.map(\.id), "replaceAll (a pull) must not touch pendingEditEvents (EV1)")
    }

    static func testArmCloudSyncDiscardsMismatchedAccountEvents() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        await db.armCloudSync(userId: "user-a") {}
        _ = try! await db.addPlannedExercises([
            PlanExerciseDraft(exerciseName: "Row", exerciseId: nil, isBodyweight: false,
                sets: [.init(targetWeight: 50, targetWeightUnit: .kg, targetReps: 10)])
        ])
        let setupEvents = await db.snapshot().pendingEditEvents
        precondition(!setupEvents.isEmpty, "setup should have produced at least one event for user-a")

        await db.disarmCloudSync(userId: "user-a")
        await db.armCloudSync(userId: "user-b") {}

        let remaining = await db.snapshot().pendingEditEvents
        precondition(remaining.isEmpty, "arming under a different userId must discard the previous account's pending events (EV9)")
    }
}
