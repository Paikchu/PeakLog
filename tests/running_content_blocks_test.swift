import Foundation

@main
struct RunningContentBlocksTestRunner {
    static func main() throws {
        try decodesRunningRecordContentBlock()
        print("running_content_blocks_test passed")
    }

    private static func decodesRunningRecordContentBlock() throws {
        let json = """
        [
          {
            "type": "running_record",
            "running_workout_id": "run-1",
            "workout_date": "2026-04-01",
            "duration_minutes": 30,
            "distance_km": 5.2,
            "source": "chat"
          }
        ]
        """

        let data = Data(json.utf8)
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: data)

        guard blocks.count == 1 else {
            preconditionFailure("Expected one content block")
        }

        guard case .runningRecord(let record) = blocks[0] else {
            preconditionFailure("Expected runningRecord content block")
        }

        precondition(record.runningWorkoutId == "run-1", "Expected running workout id to decode")
        precondition(record.durationMinutes == 30, "Expected duration to decode")
        precondition(record.distanceKm == 5.2, "Expected distance to decode")
    }
}
