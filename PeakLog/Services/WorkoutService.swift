import Foundation

/// `nonisolated` + `Sendable`: every implementation is a thin async facade over
/// the `LocalAppDatabase` actor, so nothing here belongs on the main actor.
/// Stating that explicitly is what lets the view models fan requests out with
/// `async let` (see `HistoryViewModel.loadSessionsForSelectedDateSilently`) —
/// under the module's default `@MainActor` isolation the service would be
/// main-actor-isolated non-`Sendable` state that cannot leave the main actor,
/// and the concurrent load would not compile in the Swift 6 language mode.
nonisolated protocol WorkoutServiceProtocol: Sendable {
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws
    func deleteExercise(sessionId: String, exerciseId: String) async throws
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession]
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord]
    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession
    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord
    func createCardioRecord(
        workoutDate: Date,
        metrics: CardioMetrics,
        source: RunningWorkoutSource
    ) async throws -> CardioWorkoutRecord
}

nonisolated extension WorkoutServiceProtocol {
    func createCardioRecord(
        workoutDate: Date,
        metrics: CardioMetrics,
        source: RunningWorkoutSource
    ) async throws -> CardioWorkoutRecord {
        guard metrics.activityType == .running, let distanceKm = metrics.distanceKm else {
            throw CardioMetricsError.unsupportedDistance
        }
        return try await createRunningRecord(
            workoutDate: workoutDate,
            durationMinutes: metrics.durationMinutes,
            distanceKm: distanceKm,
            source: source
        )
    }
}

nonisolated final class LocalWorkoutService: WorkoutServiceProtocol {
    private let database: LocalAppDatabase

    init(database: LocalAppDatabase) {
        self.database = database
    }

    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        try await database.updateSet(
            sessionId: sessionId,
            exerciseId: exerciseId,
            setId: setId,
            weight: weight,
            weightUnit: weightUnit,
            reps: reps
        )
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        try await database.addSet(
            sessionId: sessionId,
            exerciseId: exerciseId,
            weight: weight,
            weightUnit: weightUnit,
            reps: reps
        )
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {
        try await database.deleteSet(sessionId: sessionId, exerciseId: exerciseId, setId: setId)
    }

    func deleteExercise(sessionId: String, exerciseId: String) async throws {
        try await database.deleteExercise(sessionId: sessionId, exerciseId: exerciseId)
    }

    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        try await database.updateSetRPE(setId: setId, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        await database.activeDaysInMonth(year: year, month: month)
    }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        await database.sessionsForDay(date)
    }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] {
        await database.runningRecordsForDay(date)
    }

    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession {
        try await database.createStrengthSession(draft)
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord {
        try await database.createRunningRecord(
            workoutDate: workoutDate,
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            source: source
        )
    }

    func createCardioRecord(
        workoutDate: Date,
        metrics: CardioMetrics,
        source: RunningWorkoutSource
    ) async throws -> CardioWorkoutRecord {
        try await database.createCardioRecord(
            workoutDate: workoutDate,
            metrics: metrics,
            source: source
        )
    }
}
