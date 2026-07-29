import Supabase
import XCTest
@testable import PeakLog

final class CloudPushFirstGuardTests: XCTestCase {
    private let userId = "f98c4070-9db3-4f56-8256-3f023998e190"
    private let planId = "f476d92c-070a-4785-ae3b-966323d64d6a"
    private let dayId = "43295f91-8b0d-46a5-a8eb-7f0d085ad119"
    private let exerciseId = "6733aac5-1111-4111-8111-111111111111"
    private let setId = "ed8df7f4-81f1-406f-b6f9-dc7224499d61"
    private let remoteOnlySessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    override func tearDown() {
        PushFirstURLProtocol.reset()
        super.tearDown()
    }

    func testDirtyColdStartPushesLocalEditAndKeepsRemoteRow() async throws {
        let dates = currentDates()
        PushFirstURLProtocol.configure(
            getBodies: cloudGetBodies(weekStart: dates.weekStart, planDate: dates.planDate)
        )
        let database = await seededDatabase(
            weekStart: dates.weekStart,
            planDate: dates.planDate,
            dirty: true
        )
        let coordinator = CloudSyncCoordinator(
            client: dataClient(),
            database: database,
            userId: userId
        )

        let started = await coordinator.start()
        XCTAssertTrue(started)
        let snapshot = await database.snapshot()
        XCTAssertEqual(snapshot.activePlan.days[0].exercises[0].sets[0].targetWeight, 62.5)
        XCTAssertTrue(snapshot.strengthSessions.contains { $0.id == remoteOnlySessionId })

        let requests = PushFirstURLProtocol.requests
        let pushedSets = requests
            .filter { $0.method == "POST" && $0.table == "training_plan_sets" }
            .map(\.body)
            .joined()
        XCTAssertTrue(pushedSets.contains("62.5"))

        // The prune now names the rows it destroys (`id=in.(…)`) instead of
        // naming the survivors (`id=not.in.(…)`), so "the remote-only row was
        // kept" flips from "it appears in the DELETE filter" to "no DELETE
        // mentions it at all" — and since it is the only cloud session, the
        // diff is empty and no DELETE is issued for the table whatsoever.
        let sessionDeletes = requests.filter {
            $0.method == "DELETE" && $0.table == "workout_sessions"
        }
        XCTAssertTrue(sessionDeletes.isEmpty)
        XCTAssertFalse(requests.contains {
            $0.method == "DELETE" && $0.query.contains(remoteOnlySessionId)
        })
        let isDirty = await database.hasUnpushedLocalChanges()
        XCTAssertFalse(isDirty)
    }

    func testCleanColdStartPullsWithoutPush() async throws {
        let dates = currentDates()
        PushFirstURLProtocol.configure(
            getBodies: cloudGetBodies(weekStart: dates.weekStart, planDate: dates.planDate)
        )
        let database = await seededDatabase(
            weekStart: dates.weekStart,
            planDate: dates.planDate,
            dirty: false
        )
        let coordinator = CloudSyncCoordinator(
            client: dataClient(),
            database: database,
            userId: userId
        )

        let started = await coordinator.start()
        XCTAssertTrue(started)
        let snapshot = await database.snapshot()
        XCTAssertEqual(snapshot.activePlan.days[0].exercises[0].sets[0].targetWeight, 30)
        XCTAssertTrue(PushFirstURLProtocol.requests.allSatisfy { $0.method == "GET" })
    }

    func testUnreachableCloudDoesNotPruneAndKeepsDirtyState() async throws {
        let dates = currentDates()
        PushFirstURLProtocol.configure(getBodies: [:], failEverything: true)
        let database = await seededDatabase(
            weekStart: dates.weekStart,
            planDate: dates.planDate,
            dirty: true
        )
        let coordinator = CloudSyncCoordinator(
            client: dataClient(),
            database: database,
            userId: userId
        )

        let started = await coordinator.start()
        XCTAssertTrue(started)
        XCTAssertFalse(PushFirstURLProtocol.requests.contains { $0.method == "DELETE" })
        let isDirty = await database.hasUnpushedLocalChanges()
        XCTAssertTrue(isDirty)
        let snapshot = await database.snapshot()
        XCTAssertEqual(snapshot.activePlan.days[0].exercises[0].sets[0].targetWeight, 62.5)
    }

    private func dataClient() -> SupabaseDataClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushFirstURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sdkClient = SupabaseClientFactory(
            config: SupabaseConfig(
                url: URL(string: "https://example.supabase.co")!,
                publishableKey: "sb_publishable_test"
            ),
            authSession: session,
            apiSession: session
        ).makeAPIClient()
        return SupabaseDataClient(
            client: sdkClient,
            tokenProvider: StubTokenProvider(),
            retryEnabled: false
        )
    }

    private func currentDates() -> (weekStart: String, planDate: String) {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return (
            WorkoutDateFormatter().string(from: weekStart),
            WorkoutDateFormatter().string(from: today)
        )
    }

    private func seededDatabase(
        weekStart: String,
        planDate: String,
        dirty: Bool
    ) async -> LocalAppDatabase {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-push-first-\(UUID().uuidString).json")
        let database = LocalAppDatabase(fileURL: fileURL)
        await database.prepareForCloudUser(userId)
        let seeded = await database.fetchProfile()
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
        let planSet = TrainingPlanSet(
            id: setId,
            setIndex: 1,
            targetWeight: 62.5,
            targetWeightUnit: .kg,
            targetReps: 8
        )
        let exercise = TrainingPlanExercise(
            id: exerciseId,
            orderIndex: 0,
            exerciseName: "硬拉",
            exerciseId: "deadlift",
            exerciseLoadType: .weighted,
            progressionMode: "ai_generated",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: [planSet]
        )
        let day = TrainingPlanDay(
            id: dayId,
            planDate: planDate,
            dayIndex: 1,
            title: "全身训练 C",
            focus: nil,
            status: "planned",
            exercises: [exercise]
        )
        let plan = TrainingPlan(
            id: planId,
            weekStartDate: weekStart,
            goalSummary: "local goal",
            coachSummary: "local coach",
            days: [day],
            revision: 2
        )
        await database.replaceAll(
            profile: profile,
            activePlan: plan,
            strengthSessions: [],
            runningRecords: [],
            customExercises: [],
            goalSpec: nil
        )
        if dirty {
            _ = try? await database.updatePlannedSet(
                planSetId: setId,
                targetWeight: 62.5,
                targetWeightUnit: .kg,
                targetReps: 8
            )
        }
        return database
    }

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
              "order_index":0,"exercise_name":"硬拉","exercise_id":"deadlift",
              "progression_mode":"ai_generated","exercise_load_type":"weighted","notes":null,
              "item_type":"strength"}]
            """,
            "training_plan_sets": """
            [{"id":"\(setId)","plan_id":"\(planId)","plan_exercise_id":"\(exerciseId)",
              "user_id":"\(userId)","set_index":1,"target_weight":30,"target_weight_unit":"kg",
              "target_reps":8,"completed_at":null,"linked_exercise_set_id":null}]
            """,
            "workout_sessions": """
            [{"id":"\(remoteOnlySessionId)","user_id":"\(userId)","workout_date":"\(planDate)",
              "title":"Logged on another device","source_type":"manual","duration_seconds":null,
              "created_at":"2026-07-16T10:00:00Z","updated_at":"2026-07-16T10:00:00Z"}]
            """
        ]
    }
}

private final class PushFirstURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let table: String
        let query: String
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var getBodies: [String: String] = [:]
    nonisolated(unsafe) private static var failEverything = false
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    static func configure(getBodies: [String: String], failEverything: Bool = false) {
        lock.withLock {
            self.getBodies = getBodies
            self.failEverything = failEverything
            recorded = []
        }
    }

    static func reset() {
        configure(getBodies: [:])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let table = request.url!.lastPathComponent
        let body = Self.requestBody(request)
        let result = Self.lock.withLock { () -> (Bool, String) in
            Self.recorded.append(Recorded(
                method: method,
                table: table,
                query: request.url?.query ?? "",
                body: body
            ))
            return (Self.failEverything, Self.getBodies[table] ?? "[]")
        }

        if result.0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: method == "GET" ? 200 : 204,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: method == "GET" ? Data(result.1.utf8) : Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
