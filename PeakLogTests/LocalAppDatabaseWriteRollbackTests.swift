import XCTest
@testable import PeakLog

final class LocalAppDatabaseWriteRollbackTests: XCTestCase {
    func testUpdateFailureRestoresSnapshotAndDoesNotNotifyChange() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)
        let changeCounter = ChangeCounter()
        await database.armCloudSync(userId: "local-user") { changeCounter.increment() }
        let before = await database.snapshot()
        try replaceStateFileWithDirectory(fileURL)

        do {
            _ = try await database.updatePreferences(UpdatePreferencesRequest(
                notificationsEnabled: nil,
                darkModeEnabled: false,
                weightUnit: nil,
                timezone: nil,
                language: nil
            ))
            XCTFail("expected write failure")
        } catch {
            // Expected: the state path is a directory.
        }

        let after = await database.snapshot()
        XCTAssertEqual(try encode(before), try encode(after))
        let observedChangeCount = changeCounter.value
        XCTAssertEqual(observedChangeCount, 0)
    }

    func testDeleteFailureRestoresSnapshot() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)
        let before = await database.snapshot()
        try replaceStateFileWithDirectory(fileURL)

        do {
            try await database.deleteSet(sessionId: "seed-session-1", exerciseId: "seed-exercise-1", setId: "seed-set-1")
            XCTFail("expected write failure")
        } catch {
            // Expected: the state path is a directory.
        }

        let after = await database.snapshot()
        XCTAssertEqual(try encode(before), try encode(after))
    }

    func testBatchMutationFailureRestoresSnapshot() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)
        let before = await database.snapshot()
        try replaceStateFileWithDirectory(fileURL)

        do {
            _ = try await database.addPlannedExercises([PlanExerciseDraft(exerciseName: "Cable Row", isBodyweight: false, sets: [])])
            XCTFail("expected write failure")
        } catch {
            // Expected: the state path is a directory.
        }

        let after = await database.snapshot()
        XCTAssertEqual(try encode(before), try encode(after))
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-write-rollback-(UUID().uuidString).json")
    }

    private func replaceStateFileWithDirectory(_ fileURL: URL) throws {
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    }

    private func encode(_ snapshot: LocalDataSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(SnapshotEnvelope(snapshot))
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct SnapshotEnvelope: Codable {
    let profile: UserProfile
    let activePlan: TrainingPlan
    let strengthSessions: [WorkoutSession]
    let runningRecords: [RunningWorkoutRecord]
    let customExercises: [ExerciseDefinition]
    let goalSpec: GoalSpec?
    let pendingEditEvents: [PlanEditEvent]

    init(_ snapshot: LocalDataSnapshot) {
        profile = snapshot.profile
        activePlan = snapshot.activePlan
        strengthSessions = snapshot.strengthSessions
        runningRecords = snapshot.runningRecords
        customExercises = snapshot.customExercises
        goalSpec = snapshot.goalSpec
        pendingEditEvents = snapshot.pendingEditEvents
    }
}
