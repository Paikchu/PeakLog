import Supabase
import XCTest
@testable import PeakLog

final class SupabaseDataClientTests: XCTestCase {
    override func tearDown() {
        SDKRecordingURLProtocol.reset()
        super.tearDown()
    }

    func testFetchMapsSelectFilterOrderAndLimit() async throws {
        SDKRecordingURLProtocol.enqueueJSON(#"[{"id":"plan-1","focus":"strength"}]"#)
        let client = makeClient()

        let rows = try await client.fetch(TestReadRow.self, table: "training_plans", query: [
            URLQueryItem(name: "select", value: "id,focus"),
            URLQueryItem(name: "status", value: "eq.active"),
            URLQueryItem(name: "week_start_date", value: "lte.2026-07-28"),
            URLQueryItem(name: "order", value: "week_start_date.desc"),
            URLQueryItem(name: "limit", value: "1")
        ])

        XCTAssertEqual(rows, [TestReadRow(id: "plan-1", focus: "strength")])
        let items = try queryItems()
        XCTAssertEqual(items["select"], "id,focus")
        XCTAssertEqual(items["status"], "eq.active")
        XCTAssertEqual(items["week_start_date"], "lte.2026-07-28")
        XCTAssertTrue(items["order"]?.hasPrefix("week_start_date.desc") == true)
        XCTAssertEqual(items["limit"], "1")
    }

    func testBulkRowsFillMissingOptionalColumnsWithNull() throws {
        let rows = try SupabaseDataClient.normalizedBulkRows([
            TestWriteRow(id: "day-1", focus: "legs"),
            TestWriteRow(id: "day-2", focus: nil)
        ])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["focus"], .string("legs"))
        XCTAssertEqual(rows[1]["focus"], .null)
    }

    func testBulkRowsDoNotInventColumnsOmittedByEveryRow() throws {
        let rows = try SupabaseDataClient.normalizedBulkRows([
            RevisionOmittingRow(id: "plan-1", revision: 2),
            RevisionOmittingRow(id: "plan-2", revision: 3)
        ])

        XCTAssertTrue(rows.allSatisfy { $0["revision"] == nil })
        XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["id", "status"] })
    }

    func testBulkRowsPreserveNestedPayloadsAndSingleRowOmissions() throws {
        let events = try SupabaseDataClient.normalizedBulkRows([
            EventWriteRow(id: "event-1", exerciseName: "硬拉", payload: ["targetWeight": 60]),
            EventWriteRow(id: "event-2", exerciseName: nil, payload: [:])
        ])
        XCTAssertEqual(events[0]["payload"], .object(["targetWeight": .integer(60)]))
        XCTAssertEqual(events[1]["exerciseName"], .null)
        XCTAssertEqual(events[1]["payload"], .object([:]))

        let single = try SupabaseDataClient.normalizedBulkRows([
            TestWriteRow(id: "day-1", focus: nil)
        ])
        XCTAssertNil(single[0]["focus"])
    }

    func testUpsertAllSyncTablesUsesMinimalReturning() async throws {
        let tables = [
            "profiles", "user_preferences", "user_goal_specs", "custom_exercises",
            "workout_sessions", "exercises", "exercise_sets", "running_workouts",
            "training_plans", "training_plan_days", "training_plan_exercises",
            "training_plan_sets", "plan_edit_events"
        ]
        for _ in tables {
            SDKRecordingURLProtocol.enqueue(status: 204)
        }
        let client = makeClient()

        for table in tables {
            try await client.upsert(table: table, rows: [TestWriteRow(id: "id", focus: nil)])
        }

        XCTAssertEqual(SDKRecordingURLProtocol.requests.count, tables.count)
        for (request, table) in zip(SDKRecordingURLProtocol.requests, tables) {
            XCTAssertTrue(request.url?.path.hasSuffix("/rest/v1/\(table)") == true)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Prefer")?.contains("return=minimal") == true)
        }
    }

    func testUpdateUsesFiltersAndMinimalReturning() async throws {
        SDKRecordingURLProtocol.enqueue(status: 204)
        let client = makeClient()

        try await client.update(
            table: "profiles",
            match: [URLQueryItem(name: "id", value: "eq.user-1")],
            row: TestWriteRow(id: "user-1", focus: nil)
        )

        let request = try XCTUnwrap(SDKRecordingURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(try queryItems()["id"], "eq.user-1")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Prefer")?.contains("return=minimal") == true)
    }

    func testInsertIgnoringDuplicatesUsesSDKIgnoreDuplicates() async throws {
        SDKRecordingURLProtocol.enqueue(status: 204)
        let client = makeClient()

        try await client.insertIgnoringDuplicates(
            table: "plan_edit_events",
            rows: [TestWriteRow(id: "event-1", focus: nil)]
        )

        let prefer = try XCTUnwrap(SDKRecordingURLProtocol.requests.last?
            .value(forHTTPHeaderField: "Prefer"))
        XCTAssertTrue(prefer.contains("resolution=ignore-duplicates"))
        XCTAssertTrue(prefer.contains("return=minimal"))
    }

    func testDeleteNotInHandlesEmptyAndScopedNonEmptySets() async throws {
        SDKRecordingURLProtocol.enqueue(status: 204)
        SDKRecordingURLProtocol.enqueue(status: 204)
        let client = makeClient()

        try await client.deleteNotIn(table: "running_workouts", keepIds: [])
        try await client.deleteNotIn(
            table: "training_plan_days",
            keepIds: ["day-1", "day-2"],
            extraFilters: [URLQueryItem(name: "plan_id", value: "eq.plan-1")]
        )

        let emptyItems = try queryItems(for: SDKRecordingURLProtocol.requests[0])
        XCTAssertEqual(emptyItems["id"], "not.is.null")
        let scopedItems = try queryItems(for: SDKRecordingURLProtocol.requests[1])
        XCTAssertEqual(scopedItems["plan_id"], "eq.plan-1")
        XCTAssertEqual(scopedItems["id"], "not.in.(day-1,day-2)")
    }

    func testTokenFailureSendsNoRequest() async {
        let tokenProvider = StubTokenProvider(.failure)
        let client = makeClient(tokenProvider: tokenProvider)

        do {
            _ = try await client.fetch(TestReadRow.self, table: "profiles", query: [])
            XCTFail("Expected unauthorized")
        } catch CloudError.unauthorized {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(SDKRecordingURLProtocol.requests.isEmpty)
    }

    func testGETRetries503And520WhenEnabled() async throws {
        for status in [503, 520] {
            SDKRecordingURLProtocol.reset()
            SDKRecordingURLProtocol.enqueue(status: status, body: Data("temporary".utf8))
            SDKRecordingURLProtocol.enqueueJSON("[]")
            let client = makeClient(retryEnabled: true)

            let rows = try await client.fetch(TestReadRow.self, table: "profiles", query: [])

            XCTAssertTrue(rows.isEmpty)
            XCTAssertEqual(SDKRecordingURLProtocol.requests.count, 2)
        }
    }

    func testErrorsMapToUnauthorizedNetworkAndRemote() async {
        let client = makeClient()

        SDKRecordingURLProtocol.enqueue(status: 401, body: Data("unauthorized".utf8))
        await assertCloudError(.unauthorized) {
            _ = try await client.fetch(TestReadRow.self, table: "profiles", query: [])
        }

        SDKRecordingURLProtocol.enqueue(error: URLError(.notConnectedToInternet))
        await assertCloudError(.network) {
            _ = try await client.fetch(TestReadRow.self, table: "profiles", query: [])
        }

        SDKRecordingURLProtocol.enqueueJSON(
            #"{"code":"PGRST999","message":"remote failure","details":null,"hint":null}"#,
            status: 409
        )
        await assertCloudError(.remote(code: "PGRST999", message: "remote failure")) {
            _ = try await client.fetch(TestReadRow.self, table: "profiles", query: [])
        }
    }

    private func makeClient(
        tokenProvider: StubTokenProvider = StubTokenProvider(),
        retryEnabled: Bool = false
    ) -> SupabaseDataClient {
        SupabaseDataClient(
            client: SupabaseSDKTestClient.make(),
            tokenProvider: tokenProvider,
            retryEnabled: retryEnabled
        )
    }

    private func queryItems(for request: URLRequest? = SDKRecordingURLProtocol.requests.last) throws -> [String: String] {
        let request = try XCTUnwrap(request)
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            guard let value = $0.value else { return nil }
            return ($0.name, value)
        })
    }

    private func assertCloudError(
        _ expected: CloudError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as CloudError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct TestReadRow: Codable, Equatable {
    let id: String
    let focus: String?
}

private struct TestWriteRow: Encodable {
    let id: String
    let focus: String?
}

private struct RevisionOmittingRow: Encodable {
    let id: String
    let status = "active"
    let revision: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case status
    }
}

private struct EventWriteRow: Encodable {
    let id: String
    let exerciseName: String?
    let payload: [String: Int]
}
