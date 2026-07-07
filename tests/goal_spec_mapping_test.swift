import Foundation

// Logic test: GoalSpec validation boundaries + GoalSpec <-> GoalSpecRow round trip.
// Compile with:
//   swiftc -parse-as-library \
//     PeakLog/Models/ExerciseLibraryModels.swift PeakLog/Models/GoalSpec.swift \
//     PeakLog/Services/Cloud/CloudRows.swift \
//     tests/goal_spec_mapping_test.swift -o /tmp/gs && /tmp/gs

@main
struct GoalSpecMappingTest {
    static func main() {
        testValidationBoundaries()
        testRoundTrip()
        testUnknownRawValuesFallBackToDefaults()
        print("goal_spec_mapping_test passed")
    }

    static func testValidationBoundaries() {
        precondition(GoalSpec.default.isValid, "default spec must be valid")

        var spec = GoalSpec.default
        spec.daysPerWeek = 1
        precondition(spec.isValid, "1 day/week is the lower bound, must be valid")
        spec.daysPerWeek = 7
        precondition(spec.isValid, "7 days/week is the upper bound, must be valid")
        spec.daysPerWeek = 0
        precondition(!spec.isValid, "0 days/week must be invalid")
        spec.daysPerWeek = 8
        precondition(!spec.isValid, "8 days/week must be invalid")
        spec.daysPerWeek = 3

        spec.sessionMinutes = 15
        precondition(spec.isValid, "15 min is the lower bound, must be valid")
        spec.sessionMinutes = 240
        precondition(spec.isValid, "240 min is the upper bound, must be valid")
        spec.sessionMinutes = 14
        precondition(!spec.isValid, "14 min must be invalid")
        spec.sessionMinutes = 241
        precondition(!spec.isValid, "241 min must be invalid")
    }

    static func testRoundTrip() {
        let userId = "11111111-1111-1111-1111-111111111111"
        let spec = GoalSpec(
            objective: .strength,
            daysPerWeek: 4,
            sessionMinutes: 75,
            equipment: [.barbell, .dumbbell],
            focusAreas: [.chest, .back],
            experience: .intermediate,
            note: "focus on bench and row"
        )

        let row = CloudMapper.goalSpecRow(from: spec, userId: userId)
        precondition(row.user_id == userId, "PK must be the user id")
        precondition(row.objective == "strength")
        precondition(row.equipment == ["barbell", "dumbbell"])
        precondition(row.focus_areas == ["chest", "back"])

        let back = CloudMapper.goalSpec(from: row)
        precondition(back?.objective == .strength)
        precondition(back?.daysPerWeek == 4)
        precondition(back?.sessionMinutes == 75)
        precondition(back?.equipment == [.barbell, .dumbbell])
        precondition(back?.focusAreas == [.chest, .back])
        precondition(back?.experience == .intermediate)
        precondition(back?.note == "focus on bench and row")

        precondition(CloudMapper.goalSpec(from: nil) == nil, "no row => no spec (G5)")
    }

    static func testUnknownRawValuesFallBackToDefaults() {
        // A row with a value outside the client's known enum cases (e.g. a
        // future server-side addition) must not crash decoding — it should
        // fall back to a safe default instead.
        let row = GoalSpecRow(
            user_id: "u", objective: "some_future_objective", days_per_week: 5,
            session_minutes: 45, equipment: ["barbell", "some_future_equipment"],
            focus_areas: ["chest", "some_future_group"], experience: "some_future_level", note: nil
        )
        let spec = CloudMapper.goalSpec(from: row)
        precondition(spec?.objective == .general, "unknown objective falls back to .general")
        precondition(spec?.experience == .beginner, "unknown experience falls back to .beginner")
        precondition(spec?.equipment == [.barbell], "unknown equipment values are dropped, known ones kept")
        precondition(spec?.focusAreas == [.chest], "unknown focus areas are dropped, known ones kept")
    }
}
