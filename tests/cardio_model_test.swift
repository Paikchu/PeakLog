import Foundation

@main
struct CardioModelTestRunner {
    static func main() throws {
        try legacyPlanExerciseDefaultsToStrength()
        try legacyRunningRecordDefaultsToRunning()
        try cardioMetricsValidateByActivityType()
        print("cardio_model_test passed")
    }

    private static func legacyPlanExerciseDefaultsToStrength() throws {
        let json = #"{"id":"exercise-1","orderIndex":0,"exerciseName":"Squat","exerciseId":"squat","exerciseLoadType":"weighted","progressionMode":"maintain","notes":null,"previousPerformanceSummary":null,"aiSuggestion":null,"sets":[]}"#
        let exercise = try JSONDecoder().decode(TrainingPlanExercise.self, from: Data(json.utf8))
        precondition(exercise.itemType == .strength)
        precondition(exercise.cardioActivityType == nil)
    }

    private static func legacyRunningRecordDefaultsToRunning() throws {
        let json = #"{"id":"run-1","userId":"user-1","workoutDate":0,"durationMinutes":30,"distanceKm":5,"source":"manual","createdAt":0,"updatedAt":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(CardioWorkoutRecord.self, from: Data(json.utf8))
        precondition(record.activityType == .running)
        precondition(record.distanceKm == 5)
        precondition(record.rpe == nil)
    }

    private static func cardioMetricsValidateByActivityType() throws {
        let run = try CardioMetrics(activityType: .running, durationMinutes: 30, distanceKm: 5, rpe: 6)
        precondition(run.distanceKm == 5)

        let elliptical = try CardioMetrics(activityType: .elliptical, durationMinutes: 20, distanceKm: nil, rpe: 5)
        precondition(elliptical.distanceKm == nil)

        expectInvalid { _ = try CardioMetrics(activityType: .cycling, durationMinutes: 0, distanceKm: 10, rpe: 5) }
        expectInvalid { _ = try CardioMetrics(activityType: .running, durationMinutes: 20, distanceKm: -1, rpe: 5) }
        expectInvalid { _ = try CardioMetrics(activityType: .elliptical, durationMinutes: 20, distanceKm: 2, rpe: 5) }
        expectInvalid { _ = try CardioMetrics(activityType: .stairClimber, durationMinutes: 20, distanceKm: nil, rpe: 11) }
    }

    private static func expectInvalid(_ body: () throws -> Void) {
        do {
            try body()
            preconditionFailure("Expected invalid cardio metrics")
        } catch {
            return
        }
    }
}
