import Foundation

// Logic test for `SupabaseDataClient.normalizedBulkBody` — the PGRST102 fix.
//
// PostgREST rejects a bulk payload whose objects don't all carry the same key
// set ("All object keys must match"), and Swift's synthesized Encodable omits
// nil optionals. A plan day with `focus` next to a rest day without it made
// every full-state push fail deterministically (and silently), which is what
// reverted local plan edits on restart. The normalizer unions keys across
// rows and fills gaps with explicit JSON null.
//
// Coverage:
//   1. heterogeneous rows: every row gains the full key union; the gap is an
//      explicit null; present values are untouched.
//   2. a key omitted by EVERY row stays omitted (the training_plans.revision
//      contract: an omitted column is preserved on conflict).
//   3. homogeneous rows and single rows pass through the plain encoder path.
//   4. nested containers (jsonb-style payloads) survive normalization.
//
// Compile with:
//   swiftc -parse-as-library \
//     PeakLog/Services/Auth/AuthModels.swift \
//     PeakLog/Services/Auth/AuthProviding.swift \
//     PeakLog/Services/SupabaseConfig.swift \
//     PeakLog/Services/Cloud/SupabaseDataClient.swift \
//     tests/cloud_push_bulk_body_test.swift -o /tmp/cpbb && /tmp/cpbb

private struct DayRowFixture: Encodable {
    let id: String
    let title: String
    var focus: String?
}

private struct EventRowFixture: Encodable {
    let id: String
    var exercise_name: String?
    var payload: [String: Int]
}

/// Mimics TrainingPlanRow: `revision` exists on the type but is never encoded.
private struct RevisionOmittingFixture: Encodable {
    let id: String
    var status: String
    var revision: Int = 0

    private enum CodingKeys: String, CodingKey { case id, status }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(status, forKey: .status)
    }
}

private func decodeObjects(_ data: Data) -> [[String: Any]] {
    guard let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        preconditionFailure("normalized body must remain a JSON array of objects")
    }
    return objects
}

@main
struct CloudPushBulkBodyTest {
    static func main() throws {
        try testHeterogeneousRowsGainExplicitNulls()
        try testKeyOmittedByEveryRowStaysOmitted()
        try testUniformRowsPassThrough()
        try testNestedPayloadSurvives()
        print("cloud_push_bulk_body_test passed")
    }

    // 1. The PGRST102 repro: one row carries `focus`, the other does not.
    static func testHeterogeneousRowsGainExplicitNulls() throws {
        let rows = [
            DayRowFixture(id: "d1", title: "全身训练 A", focus: "push"),
            DayRowFixture(id: "d2", title: "休息", focus: nil)
        ]
        let objects = decodeObjects(try SupabaseDataClient.normalizedBulkBody(rows))

        precondition(objects.count == 2, "row count preserved")
        for object in objects {
            precondition(Set(object.keys) == ["id", "title", "focus"],
                "every row must carry the full key union, got \(object.keys.sorted())")
        }
        precondition(objects[0]["focus"] as? String == "push", "present value untouched")
        precondition(objects[1]["focus"] is NSNull,
            "omitted optional must become explicit null, got \(objects[1]["focus"] ?? "missing")")
        precondition(objects[1]["title"] as? String == "休息", "non-optional values untouched")
    }

    // 2. revision-style contract: a key no row encodes must NOT be invented.
    static func testKeyOmittedByEveryRowStaysOmitted() throws {
        let rows = [
            RevisionOmittingFixture(id: "p1", status: "active", revision: 3),
            RevisionOmittingFixture(id: "p2", status: "archived", revision: 5)
        ]
        let objects = decodeObjects(try SupabaseDataClient.normalizedBulkBody(rows))
        for object in objects {
            precondition(object["revision"] == nil,
                "a key omitted by every row must stay omitted (upsert must not touch it)")
            precondition(Set(object.keys) == ["id", "status"], "no keys invented")
        }
    }

    // 3. Uniform batches (and single rows) take the untouched-encoder path.
    static func testUniformRowsPassThrough() throws {
        let uniform = [
            DayRowFixture(id: "d1", title: "a", focus: "x"),
            DayRowFixture(id: "d2", title: "b", focus: "y")
        ]
        let uniformObjects = decodeObjects(try SupabaseDataClient.normalizedBulkBody(uniform))
        precondition(uniformObjects.allSatisfy { !($0["focus"] is NSNull) },
            "uniform rows need no null filling")

        // JSON key order is unspecified, so compare semantics, not bytes: a
        // single row can't be heterogeneous, so no null may be invented.
        let single = [DayRowFixture(id: "d1", title: "solo", focus: nil)]
        let singleObjects = decodeObjects(try SupabaseDataClient.normalizedBulkBody(single))
        precondition(singleObjects.count == 1, "row count preserved")
        precondition(Set(singleObjects[0].keys) == ["id", "title"],
            "a single row must pass through unchanged (no null invented for its nil optional)")
        precondition(singleObjects[0]["id"] as? String == "d1"
            && singleObjects[0]["title"] as? String == "solo", "values untouched")
    }

    // 4. Nested jsonb-style payloads survive the round trip.
    static func testNestedPayloadSurvives() throws {
        let rows = [
            EventRowFixture(id: "e1", exercise_name: "硬拉", payload: ["targetWeight": 60]),
            EventRowFixture(id: "e2", exercise_name: nil, payload: [:])
        ]
        let objects = decodeObjects(try SupabaseDataClient.normalizedBulkBody(rows))
        precondition((objects[0]["payload"] as? [String: Any])?["targetWeight"] as? Int == 60,
            "nested payload values must survive normalization")
        precondition(objects[1]["exercise_name"] is NSNull, "nil optional filled with null")
        precondition((objects[1]["payload"] as? [String: Any])?.isEmpty == true,
            "empty nested payload preserved")
    }
}
