import XCTest
@testable import PeakLog

final class PeakLogSmokeTests: XCTestCase {
    func testSwitchingAccountsClearsPreviousUsersSensitiveLocalData() async throws {
        let databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-isolation-\(UUID().uuidString).json")
        let database = LocalAppDatabase(fileURL: databaseFileURL)
        defer { try? FileManager.default.removeItem(at: databaseFileURL) }

        await database.prepareForCloudUser("user-a")
        let seed = await database.snapshot()
        let userAProfile = UserProfile(
            id: "user-a",
            displayName: seed.profile.displayName,
            avatarURL: seed.profile.avatarURL,
            membershipLevel: seed.profile.membershipLevel,
            stats: seed.profile.stats,
            preferences: seed.profile.preferences,
            fitnessGoalSummary: seed.profile.fitnessGoalSummary,
            exercisePRs: seed.profile.exercisePRs
        )
        let now = Date()
        let session = WorkoutSession(
            id: UUID().uuidString,
            userId: "user-a",
            date: now,
            durationMinutes: 45,
            label: "A private workout",
            exercises: [],
            createdAt: now,
            updatedAt: now
        )
        let run = RunningWorkoutRecord(
            id: UUID().uuidString,
            userId: "user-a",
            workoutDate: now,
            durationMinutes: 30,
            distanceKm: 5,
            source: .manual,
            createdAt: now,
            updatedAt: now
        )
        let custom = ExerciseDefinition(
            id: "custom-\(UUID().uuidString)",
            nameEN: "A Private Movement",
            nameZH: "A 私人动作",
            muscleGroup: .chest,
            equipment: .other,
            loadType: .weighted,
            isCustom: true
        )
        await database.replaceAll(
            profile: userAProfile,
            activePlan: seed.activePlan,
            strengthSessions: [session],
            runningRecords: [run],
            customExercises: [custom],
            goalSpec: seed.goalSpec
        )

        await database.prepareForCloudUser("user-b")
        let userB = await database.snapshot()

        XCTAssertFalse(userB.strengthSessions.contains(where: { $0.userId == "user-a" }))
        XCTAssertFalse(userB.runningRecords.contains(where: { $0.userId == "user-a" }))
        XCTAssertFalse(userB.customExercises.contains(where: { $0.id == custom.id }))

        await database.prepareForCloudUser("user-a")
        await database.mergeFromCloud(
            profile: userAProfile,
            activePlan: seed.activePlan,
            strengthSessions: [session],
            runningRecords: [run],
            customExercises: [custom],
            goalSpec: seed.goalSpec
        )
        let restoredUserA = await database.snapshot()

        XCTAssertEqual(restoredUserA.strengthSessions.map(\.id), [session.id])
        XCTAssertEqual(restoredUserA.runningRecords.map(\.id), [run.id])
        XCTAssertTrue(restoredUserA.customExercises.contains(where: { $0.id == custom.id }))
    }

    func testCloudMapperRejectsDomainRecordsOwnedByAnotherUser() async throws {
        let databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-account-isolation-\(UUID().uuidString).json")
        let database = LocalAppDatabase(fileURL: databaseFileURL)
        defer { try? FileManager.default.removeItem(at: databaseFileURL) }
        let seed = await database.snapshot()
        let now = Date()
        let foreignSession = WorkoutSession(
            id: UUID().uuidString,
            userId: "user-a",
            date: now,
            durationMinutes: nil,
            label: nil,
            exercises: [],
            createdAt: now,
            updatedAt: now
        )
        let snapshot = LocalDataSnapshot(
            profile: UserProfile(
                id: "user-b",
                displayName: seed.profile.displayName,
                avatarURL: seed.profile.avatarURL,
                membershipLevel: seed.profile.membershipLevel,
                stats: seed.profile.stats,
                preferences: seed.profile.preferences,
                fitnessGoalSummary: seed.profile.fitnessGoalSummary,
                exercisePRs: seed.profile.exercisePRs
            ),
            activePlan: seed.activePlan,
            strengthSessions: [foreignSession],
            runningRecords: [],
            customExercises: [],
            goalSpec: nil,
            pendingEditEvents: []
        )

        XCTAssertThrowsError(try CloudMapper.pushBundle(from: snapshot, userId: "user-b"))

        let foreignRun = RunningWorkoutRecord(
            id: UUID().uuidString,
            userId: "user-a",
            workoutDate: now,
            durationMinutes: 20,
            distanceKm: 3,
            source: .manual,
            createdAt: now,
            updatedAt: now
        )
        let runningSnapshot = LocalDataSnapshot(
            profile: snapshot.profile,
            activePlan: snapshot.activePlan,
            strengthSessions: [],
            runningRecords: [foreignRun],
            customExercises: [],
            goalSpec: nil,
            pendingEditEvents: []
        )
        XCTAssertThrowsError(try CloudMapper.pushBundle(from: runningSnapshot, userId: "user-b"))
    }

    func testWorkoutHistoryAggregatorMergesSessionsForHistory() {
        let now = Date(timeIntervalSince1970: 1_763_545_200)
        let day = ISO8601DateFormatter().date(from: "2026-03-19T00:00:00Z") ?? now

        let morningSession = WorkoutSession(
            id: "session-1",
            userId: "user-1",
            date: day,
            durationMinutes: 20,
            label: "Morning",
            exercises: [
                Exercise(
                    id: "bench-1",
                    name: "bench press",
                    sets: [
                        ExerciseSet(id: "set-1", setIndex: 1, weight: 80, weightUnit: .kg, reps: 10),
                        ExerciseSet(id: "set-2", setIndex: 2, weight: 80, weightUnit: .kg, reps: 10),
                    ]
                ),
            ],
            createdAt: now,
            updatedAt: now
        )

        let eveningSession = WorkoutSession(
            id: "session-2",
            userId: "user-1",
            date: day,
            durationMinutes: 30,
            label: "Evening",
            exercises: [
                Exercise(
                    id: "bench-2",
                    name: "bench press",
                    sets: [
                        ExerciseSet(id: "set-3", setIndex: 1, weight: 82.5, weightUnit: .kg, reps: 8),
                    ]
                ),
            ],
            createdAt: now.addingTimeInterval(3600),
            updatedAt: now.addingTimeInterval(3600)
        )

        let merged = WorkoutHistoryAggregator.mergeSessionsForHistory([morningSession, eveningSession])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].durationMinutes, 50)
        XCTAssertEqual(merged[0].exercises.count, 1)
        XCTAssertEqual(merged[0].exercises[0].sets.map(\.setIndex), [1, 2, 3])
    }

    func testPlanCompletionWithoutLoggedSetIsClearedWhenCloudStateLoads() async throws {
        let databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-completion-sanitize-\(UUID().uuidString).json")
        let database = LocalAppDatabase(fileURL: databaseFileURL)
        defer { try? FileManager.default.removeItem(at: databaseFileURL) }

        let snapshot = await database.snapshot()
        var dirtyPlan = snapshot.activePlan
        dirtyPlan.days[0].exercises[0].sets[0].completedAt = Date()
        dirtyPlan.days[0].exercises[0].sets[0].linkedExerciseSetId = "missing-set"

        await database.replaceAll(
            profile: snapshot.profile,
            activePlan: dirtyPlan,
            strengthSessions: [],
            runningRecords: [],
            customExercises: snapshot.customExercises,
            goalSpec: snapshot.goalSpec
        )

        let maybeLoadedPlan = await database.activePlan()
        let loadedPlan = try XCTUnwrap(maybeLoadedPlan)
        XCTAssertFalse(loadedPlan.days[0].exercises[0].sets[0].isCompleted)
        XCTAssertNil(loadedPlan.days[0].exercises[0].sets[0].linkedExerciseSetId)
    }

    func testPlanCompletionWithLoggedSetSurvivesCloudStateLoad() async throws {
        let databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-completion-preserve-\(UUID().uuidString).json")
        let database = LocalAppDatabase(fileURL: databaseFileURL)
        defer { try? FileManager.default.removeItem(at: databaseFileURL) }

        let snapshot = await database.snapshot()
        var completedPlan = snapshot.activePlan
        let planDay = completedPlan.days[0]
        let planExercise = planDay.exercises[0]
        completedPlan.days[0].exercises[0].sets[0].completedAt = Date()
        completedPlan.days[0].exercises[0].sets[0].linkedExerciseSetId = "logged-set"

        let sessionDate = WorkoutDateFormatter().date(from: planDay.planDate) ?? Date()
        let session = WorkoutSession(
            id: UUID().uuidString,
            userId: snapshot.profile.id,
            date: sessionDate,
            durationMinutes: nil,
            label: planDay.title,
            exercises: [
                Exercise(
                    id: UUID().uuidString,
                    name: planExercise.exerciseName,
                    exerciseId: planExercise.exerciseId,
                    exerciseLoadType: planExercise.exerciseLoadType,
                    sets: [
                        ExerciseSet(
                            id: "logged-set",
                            setIndex: 1,
                            weight: 60,
                            weightUnit: .kg,
                            reps: 8,
                            rpe: nil
                        )
                    ]
                )
            ],
            createdAt: Date(),
            updatedAt: Date()
        )

        await database.replaceAll(
            profile: snapshot.profile,
            activePlan: completedPlan,
            strengthSessions: [session],
            runningRecords: [],
            customExercises: snapshot.customExercises,
            goalSpec: snapshot.goalSpec
        )

        let maybeLoadedPlan = await database.activePlan()
        let loadedPlan = try XCTUnwrap(maybeLoadedPlan)
        XCTAssertTrue(loadedPlan.days[0].exercises[0].sets[0].isCompleted)
        XCTAssertEqual(loadedPlan.days[0].exercises[0].sets[0].linkedExerciseSetId, "logged-set")
    }
}
