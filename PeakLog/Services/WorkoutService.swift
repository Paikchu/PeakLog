import Foundation

protocol WorkoutServiceProtocol {
    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws
    func deleteExercise(sessionId: String, exerciseId: String) async throws
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession]
    func activeRunningDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord]
    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession
    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord
}

extension WorkoutServiceProtocol {
    func activeRunningDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        try await activeDaysInMonth(year: year, month: month)
    }
}

final class LocalWorkoutService: WorkoutServiceProtocol {
    private let database: LocalAppDatabase

    init(database: LocalAppDatabase) {
        self.database = database
    }

    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise {
        try await database.updateExerciseName(sessionId: sessionId, exerciseId: exerciseId, name: name)
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

    func activeRunningDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        await database.activeDaysInMonth(year: year, month: month)
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
}
