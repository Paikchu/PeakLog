import Foundation

@main
struct CardioModelTestRunner {
    static func main() throws {
        try legacyPlanExerciseDefaultsToStrength()
        try legacyRunningRecordDefaultsToRunning()
        try legacyCardioRPEStillDecodes()
        try unknownActivityDefaultsToRunning()
        try unknownPlanActivityDefaultsToRunning()
        try newCardioMetricsDefaultToNoRPE()
        try cardioMetricsValidateByActivityType()
        try cardioPlanTargetAcceptsEitherDurationOrDistance()
        print("cardio_model_test passed")
    }

    private static func unknownActivityDefaultsToRunning() throws {
        let json = #"{"id":"run-3","userId":"user-1","workoutDate":0,"activityType":"future_cardio","durationMinutes":30,"distanceKm":5,"source":"manual","createdAt":0,"updatedAt":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(CardioWorkoutRecord.self, from: Data(json.utf8))
        precondition(record.activityType == .running, "Unknown persisted activity must use the legacy running fallback")
    }

    private static func unknownPlanActivityDefaultsToRunning() throws {
        let json = #"{"id":"plan-cardio-1","orderIndex":0,"exerciseName":"Future Cardio","exerciseLoadType":"unknown","progressionMode":"manual","sets":[],"itemType":"cardio","cardioActivityType":"future_cardio","targetDurationMinutes":30}"#
        let exercise = try JSONDecoder().decode(TrainingPlanExercise.self, from: Data(json.utf8))
        precondition(exercise.cardioActivityType == .running, "Unknown persisted plan activity must use the running fallback")
    }

    private static func legacyCardioRPEStillDecodes() throws {
        let json = #"{"id":"run-2","userId":"user-1","workoutDate":0,"activityType":"cycling","durationMinutes":30,"distanceKm":5,"rpe":7,"source":"manual","createdAt":0,"updatedAt":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(CardioWorkoutRecord.self, from: Data(json.utf8))
        precondition(record.rpe == 7, "Legacy cardio RPE must remain decodable")
    }

    private static func newCardioMetricsDefaultToNoRPE() throws {
        let metrics = try CardioMetrics(
            activityType: .running,
            durationMinutes: 30,
            distanceKm: 5
        )
        precondition(metrics.rpe == nil)
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

    /// 计划目标和实际记录的规则不同：记录必须有时长，计划只要时长/距离有其一。
    private static func cardioPlanTargetAcceptsEitherDurationOrDistance() throws {
        let distanceOnly = try CardioPlanTarget(activityType: .running, durationMinutes: nil, distanceKm: 3)
        precondition(distanceOnly.durationMinutes == nil)
        precondition(distanceOnly.distanceKm == 3)

        let durationOnly = try CardioPlanTarget(activityType: .running, durationMinutes: 30, distanceKm: nil)
        precondition(durationOnly.durationMinutes == 30)
        precondition(durationOnly.distanceKm == nil)

        let both = try CardioPlanTarget(activityType: .cycling, durationMinutes: 45, distanceKm: 20)
        precondition(both.durationMinutes == 45 && both.distanceKm == 20)

        // 没有任何目标的有氧计划项不是计划，谁也不知道该做什么。
        expectInvalid { _ = try CardioPlanTarget(activityType: .running, durationMinutes: nil, distanceKm: nil) }
        // 椭圆机不支持距离，所以它没有「只填距离」这条路，时长仍是必填。
        expectInvalid { _ = try CardioPlanTarget(activityType: .elliptical, durationMinutes: nil, distanceKm: 5) }
        expectInvalid { _ = try CardioPlanTarget(activityType: .elliptical, durationMinutes: nil, distanceKm: nil) }
        // 填了就得是正数。
        expectInvalid { _ = try CardioPlanTarget(activityType: .running, durationMinutes: 0, distanceKm: nil) }
        expectInvalid { _ = try CardioPlanTarget(activityType: .running, durationMinutes: nil, distanceKm: 0) }

        // 实际记录这一侧不变：时长仍然是必需的（running_workouts.duration_minutes NOT NULL）。
        expectInvalid { _ = try CardioMetrics(activityType: .running, durationMinutes: 0, distanceKm: 3) }
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
