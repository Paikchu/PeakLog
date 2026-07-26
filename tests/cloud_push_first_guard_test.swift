import Foundation

// Coordinator-level test for the push-first cold start — the path the
// persisted unpushed-changes flag turns on, driven through the real
// `CloudSyncCoordinator` / `CloudSnapshotLoader` / `SupabaseDataClient` with a
// stub `URLProtocol` standing in for the network.
//
// The risk it pins down: `performPush` reconciles FULL state (bulk upsert +
// prune-not-present), so pushing from a snapshot that has never seen cloud
// state would `deleteNotIn` away any row another device added while this
// device was away. `performPush` therefore folds cloud-only records in first
// (`mergeCloudRecordsPreservingLocalEdits`), which is safe for unpushed local
// edits because record merging is `updatedAt` LWW and keeps local-only rows.
//
// Coverage:
//   1. dirty cold start pushes (does not merge cloud plan over local edits):
//      the local unpushed plan edit is what gets pushed, AND the cloud-only
//      session another device added is kept — its id appears in the
//      workout_sessions prune keep-list instead of being deleted.
//   2. a clean cold start still pulls first (cloud plan wins, no push).
//   3. when the cloud is unreachable, a dirty cold start performs NO
//      destructive request (no DELETE) and leaves the persisted flag set.
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
//     PeakLog/Services/Cloud/LocalDataSnapshot.swift PeakLog/Services/Cloud/CloudRows.swift \
//     PeakLog/Services/Cloud/CloudMapper.swift PeakLog/Services/Cloud/CloudSnapshotLoader.swift \
//     PeakLog/Services/Cloud/SupabaseDataClient.swift PeakLog/Services/Cloud/CloudSyncStatus.swift \
//     PeakLog/Services/Cloud/CloudSyncCoordinator.swift \
//     tests/cloud_push_first_guard_test.swift -o /tmp/cpfg && /tmp/cpfg

private let userId = "f98c4070-9db3-4f56-8256-3f023998e190"
private let planId = "f476d92c-070a-4785-ae3b-966323d64d6a"
private let dayId = "43295f91-8b0d-46a5-a8eb-7f0d085ad119"
private let exerciseId = "6733aac5-1111-4111-8111-111111111111"
private let setId = "ed8df7f4-81f1-406f-b6f9-dc7224499d61"
/// A strength session only the cloud knows about — another device logged it
/// while this device was holding unpushed edits.
private let remoteOnlySessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

private struct StubTokenProvider: TokenProviding {
    func validToken() async throws -> String { "stub-token" }
}

/// Serves canned PostgREST responses and records every request (method, path,
/// query, body) so assertions can inspect what the push actually sent.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let query: String
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _recorded: [Recorded] = []
    /// Table name → JSON array served for GET.
    nonisolated(unsafe) private static var _getBodies: [String: String] = [:]
    nonisolated(unsafe) private static var _failEverything = false

    static func configure(getBodies: [String: String], failEverything: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        _recorded = []
        _getBodies = getBodies
        _failEverything = failEverything
    }

    static var recorded: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let table = url.lastPathComponent
        let method = request.httpMethod ?? "GET"
        // httpBody is nil for a stream-backed upload; read the stream instead.
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            bodyData = collected
        }

        Self.lock.lock()
        Self._recorded.append(Recorded(
            method: method,
            path: table,
            query: url.query ?? "",
            body: bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        ))
        let shouldFail = Self._failEverything
        let getBody = Self._getBodies[table] ?? "[]"
        Self.lock.unlock()

        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let payload = method == "GET" ? Data(getBody.utf8) : Data()
        let response = HTTPURLResponse(
            url: url, statusCode: method == "GET" ? 200 : 204,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedClient() -> SupabaseDataClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return SupabaseDataClient(
        tokenProvider: StubTokenProvider(),
        session: URLSession(configuration: configuration)
    )
}

/// Cloud state: the plan as the server still has it (set target 30, i.e. the
/// local edit to 62.5 has never been pushed), plus one session only the cloud
/// knows about.
private func cloudGetBodies(weekStart: String, planDate: String) -> [String: String] {
    [
        "profiles": """
        [{"id":"\(userId)","display_name":"Tester","avatar_url":null,
          "membership_type":"free","timezone":"Asia/Shanghai","fitness_goal_summary":"get stronger"}]
        """,
        "user_preferences": """
        [{"user_id":"\(userId)","notifications_enabled":true,"weight_unit":"kg","language":"zh-Hans"}]
        """,
        "training_plans": """
        [{"id":"\(planId)","user_id":"\(userId)","week_start_date":"\(weekStart)","status":"active",
          "goal_snapshot":"cloud goal","coach_summary":"cloud coach","revision":2}]
        """,
        "training_plan_days": """
        [{"id":"\(dayId)","plan_id":"\(planId)","user_id":"\(userId)","plan_date":"\(planDate)",
          "day_index":1,"title":"全身训练 C","focus":null,"status":"planned"}]
        """,
        "training_plan_exercises": """
        [{"id":"\(exerciseId)","plan_id":"\(planId)","plan_day_id":"\(dayId)","user_id":"\(userId)",
          "order_index":0,"exercise_name":"硬拉","exercise_id":"deadlift","progression_mode":"ai_generated",
          "exercise_load_type":"weighted","notes":null,"item_type":"strength"}]
        """,
        "training_plan_sets": """
        [{"id":"\(setId)","plan_id":"\(planId)","plan_exercise_id":"\(exerciseId)","user_id":"\(userId)",
          "set_index":1,"target_weight":30,"target_weight_unit":"kg","target_reps":8,
          "completed_at":null,"linked_exercise_set_id":null}]
        """,
        "workout_sessions": """
        [{"id":"\(remoteOnlySessionId)","user_id":"\(userId)","workout_date":"\(planDate)",
          "title":"Logged on another device","source_type":"manual","duration_seconds":null,
          "created_at":"2026-07-16T10:00:00Z","updated_at":"2026-07-16T10:00:00Z"}]
        """
    ]
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("peaklog-push-first-test-\(UUID().uuidString).json")
}

/// Seeds a database owned by `userId` whose active plan carries an unpushed
/// local edit (set target 62.5 where the cloud still says 30).
private func seededDatabase(weekStart: String, planDate: String, dirty: Bool) async -> LocalAppDatabase {
    let db = LocalAppDatabase(fileURL: tempURL())
    await db.prepareForCloudUser(userId)
    // The profile must carry the signed-in user's id, as it would after any
    // earlier successful pull — `CloudMapper.pushBundle` refuses to push a
    // snapshot whose profile belongs to someone else (account-isolation
    // guard), and the seed profile's id is a placeholder.
    let seeded = await db.fetchProfile()
    let profile = UserProfile(
        id: userId,
        displayName: "Tester",
        avatarURL: nil,
        membershipLevel: seeded.membershipLevel,
        stats: seeded.stats,
        preferences: seeded.preferences,
        fitnessGoalSummary: "get stronger",
        exercisePRs: []
    )

    let localSet = TrainingPlanSet(
        id: setId, setIndex: 1, targetWeight: 62.5, targetWeightUnit: .kg, targetReps: 8)
    let localExercise = TrainingPlanExercise(
        id: exerciseId, orderIndex: 0, exerciseName: "硬拉", exerciseId: "deadlift",
        exerciseLoadType: .weighted, progressionMode: "ai_generated", notes: nil,
        previousPerformanceSummary: nil, aiSuggestion: nil, sets: [localSet])
    let localDay = TrainingPlanDay(
        id: dayId, planDate: planDate, dayIndex: 1, title: "全身训练 C",
        focus: nil, status: "planned", exercises: [localExercise])
    let localPlan = TrainingPlan(
        id: planId, weekStartDate: weekStart, goalSummary: "local goal",
        coachSummary: "local coach", days: [localDay], revision: 2)

    // replaceAll is setup-only (does not go through persist, so it leaves the
    // outbox flag alone); the mutation below is what marks it dirty.
    await db.replaceAll(profile: profile, activePlan: localPlan,
        strengthSessions: [], runningRecords: [], customExercises: [], goalSpec: nil)
    if dirty {
        // A real owned mutation → persist() marks the outbox dirty on disk.
        _ = try! await db.updatePlannedSet(
            planSetId: setId, targetWeight: 62.5, targetWeightUnit: .kg, targetReps: 8)
    }
    return db
}

private func bodies(of recorded: [StubURLProtocol.Recorded], method: String, table: String) -> [String] {
    recorded.filter { $0.method == method && $0.path == table }.map(\.body)
}

@main
struct CloudPushFirstGuardTest {
    static func main() async {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let weekStartString = WorkoutDateFormatter().string(from: weekStart)
        let planDateString = WorkoutDateFormatter().string(from: today)

        await testDirtyColdStartPushesLocalEditAndKeepsRemoteRow(
            weekStart: weekStartString, planDate: planDateString)
        await testCleanColdStartPullsInstead(
            weekStart: weekStartString, planDate: planDateString)
        await testUnreachableCloudMakesNoDestructiveRequest(
            weekStart: weekStartString, planDate: planDateString)
        print("cloud_push_first_guard_test passed")
    }

    // 1. Dirty cold start: local edit survives AND is pushed, while the
    //    cloud-only session is folded in rather than pruned away.
    static func testDirtyColdStartPushesLocalEditAndKeepsRemoteRow(weekStart: String, planDate: String) async {
        StubURLProtocol.configure(getBodies: cloudGetBodies(weekStart: weekStart, planDate: planDate))
        let db = await seededDatabase(weekStart: weekStart, planDate: planDate, dirty: true)
        let dirtyAtStart = await db.hasUnpushedLocalChanges()
        precondition(dirtyAtStart, "setup: outbox must be dirty")

        let coordinator = CloudSyncCoordinator(client: stubbedClient(), database: db, userId: userId)
        let started = await coordinator.start()
        precondition(started, "start() must succeed on a dirty cold start")

        // The local unpushed edit must NOT have been reverted to cloud's 30.
        let mergedSet = await db.snapshot().activePlan.days[0].exercises[0].sets[0]
        precondition(mergedSet.targetWeight == 62.5,
            "push-first must not merge the cloud plan over the unpushed local edit, got \(mergedSet.targetWeight as Any)")

        let recorded = StubURLProtocol.recorded
        // …and it must have been pushed, not just kept locally.
        let pushedSets = bodies(of: recorded, method: "POST", table: "training_plan_sets").joined()
        precondition(pushedSets.contains("62.5"),
            "the unpushed local edit must be in the pushed training_plan_sets body")

        // The cloud-only session must have been folded into the cache…
        let sessions = await db.snapshot().strengthSessions
        precondition(sessions.contains { $0.id == remoteOnlySessionId },
            "the cloud-only session must be merged in before pushing")
        // …and therefore appear in the prune keep-list rather than be deleted.
        let sessionDeletes = recorded.filter { $0.method == "DELETE" && $0.path == "workout_sessions" }
        precondition(!sessionDeletes.isEmpty, "the push must still prune workout_sessions")
        for delete in sessionDeletes {
            precondition(delete.query.contains(remoteOnlySessionId),
                "prune must keep the cloud-only session (id must be in not.in list), query: \(delete.query)")
        }

        // A successful push clears the persisted flag.
        let stillDirty = await db.hasUnpushedLocalChanges()
        precondition(!stillDirty, "a successful push must clear the persisted dirty flag")
    }

    // 2. Clean cold start keeps the old order: pull (cloud wins), no push.
    static func testCleanColdStartPullsInstead(weekStart: String, planDate: String) async {
        StubURLProtocol.configure(getBodies: cloudGetBodies(weekStart: weekStart, planDate: planDate))
        let db = await seededDatabase(weekStart: weekStart, planDate: planDate, dirty: false)
        let cleanAtStart = await db.hasUnpushedLocalChanges()
        precondition(!cleanAtStart, "setup: outbox must be clean")

        let coordinator = CloudSyncCoordinator(client: stubbedClient(), database: db, userId: userId)
        let cleanStarted = await coordinator.start()
        precondition(cleanStarted, "start() must succeed on a clean cold start")

        let mergedSet = await db.snapshot().activePlan.days[0].exercises[0].sets[0]
        precondition(mergedSet.targetWeight == 30,
            "a clean cold start must pull cloud truth (30), got \(mergedSet.targetWeight as Any)")
        let writes = StubURLProtocol.recorded.filter { $0.method != "GET" }
        precondition(writes.isEmpty,
            "a clean cold start must not push, saw \(writes.map { "\($0.method) \($0.path)" })")
    }

    // 3. Cloud unreachable: no destructive request, flag stays set for retry.
    static func testUnreachableCloudMakesNoDestructiveRequest(weekStart: String, planDate: String) async {
        StubURLProtocol.configure(getBodies: [:], failEverything: true)
        let db = await seededDatabase(weekStart: weekStart, planDate: planDate, dirty: true)

        let coordinator = CloudSyncCoordinator(client: stubbedClient(), database: db, userId: userId)
        _ = await coordinator.start()

        let destructive = StubURLProtocol.recorded.filter { $0.method == "DELETE" }
        precondition(destructive.isEmpty,
            "an unreadable cloud must not reach the prune step, saw \(destructive.map(\.path))")
        let dirtyAfterFailure = await db.hasUnpushedLocalChanges()
        precondition(dirtyAfterFailure,
            "the persisted dirty flag must survive a failed push so the next foreground retries")
        let mergedSet = await db.snapshot().activePlan.days[0].exercises[0].sets[0]
        precondition(mergedSet.targetWeight == 62.5, "the local edit must be untouched")
    }
}
