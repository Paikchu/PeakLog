import Foundation

// MARK: - Request DTOs

struct UpdateExerciseNameRequest: Encodable {
    let name: String
}

struct UpdateSetRequest: Encodable {
    let weight: Double?
    let weightUnit: WeightUnit
    let reps: Int
}

struct AddSetRequest: Encodable {
    let weight: Double?
    let weightUnit: WeightUnit
    let reps: Int
}

struct MonthWorkoutDaysResponse: Decodable {
    /// Dates that have at least one workout session
    let activeDates: [Date]
}

struct DaySessionsResponse: Decodable {
    let sessions: [WorkoutSession]
}

struct DayRunningRecordsResponse: Decodable {
    let records: [RunningWorkoutRecord]
}

// MARK: - Protocol

/// All workout CRUD and history query operations.
/// Implement `LiveWorkoutService` to connect to the real backend.
protocol WorkoutServiceProtocol {
    // MARK: Exercise editing
    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws
    func deleteExercise(sessionId: String, exerciseId: String) async throws
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet

    // MARK: History queries
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession]
    func activeRunningDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord]
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

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] {
        _ = date
        return []
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord {
        _ = (workoutDate, durationMinutes, distanceKm, source)
        throw APIError.notFound
    }
}

// MARK: - Live Implementation Stub

final class LiveWorkoutService: WorkoutServiceProtocol {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise {
        // TODO: PATCH /workout/sessions/{sessionId}/exercises/{exerciseId}
        let req = try client.request(method: "PATCH", path: "workout/sessions/\(sessionId)/exercises/\(exerciseId)", body: UpdateExerciseNameRequest(name: name))
        return try await client.execute(req)
    }

    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        // TODO: PATCH /workout/sessions/{sessionId}/exercises/{exerciseId}/sets/{setId}
        let req = try client.request(method: "PATCH", path: "workout/sessions/\(sessionId)/exercises/\(exerciseId)/sets/\(setId)", body: UpdateSetRequest(weight: weight, weightUnit: weightUnit, reps: reps))
        return try await client.execute(req)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        // TODO: POST /workout/sessions/{sessionId}/exercises/{exerciseId}/sets
        let req = try client.request(method: "POST", path: "workout/sessions/\(sessionId)/exercises/\(exerciseId)/sets", body: AddSetRequest(weight: weight, weightUnit: weightUnit, reps: reps))
        return try await client.execute(req)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {
        // TODO: DELETE /workout/sessions/{sessionId}/exercises/{exerciseId}/sets/{setId}
        struct Empty: Decodable {}
        let req = try client.request(method: "DELETE", path: "workout/sessions/\(sessionId)/exercises/\(exerciseId)/sets/\(setId)")
        let _: Empty = try await client.execute(req)
    }

    func deleteExercise(sessionId: String, exerciseId: String) async throws {
        // TODO: DELETE /workout/sessions/{sessionId}/exercises/{exerciseId}
        struct Empty: Decodable {}
        let req = try client.request(method: "DELETE", path: "workout/sessions/\(sessionId)/exercises/\(exerciseId)")
        let _: Empty = try await client.execute(req)
    }

    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        _ = (setId, rpe)
        throw APIError.notFound
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        // TODO: GET /workout/calendar?year={year}&month={month}
        let req = try client.request(path: "workout/calendar", queryItems: [
            URLQueryItem(name: "year", value: "\(year)"),
            URLQueryItem(name: "month", value: "\(month)")
        ])
        let res: MonthWorkoutDaysResponse = try await client.execute(req)
        return res.activeDates
    }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        // TODO: GET /workout/sessions?date={ISO8601 date}
        let formatter = WorkoutDateFormatter()
        let req = try client.request(path: "workout/sessions", queryItems: [
            URLQueryItem(name: "date", value: formatter.string(from: date))
        ])
        let res: DaySessionsResponse = try await client.execute(req)
        return res.sessions
    }

    func activeRunningDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        try await activeDaysInMonth(year: year, month: month)
    }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] {
        let formatter = WorkoutDateFormatter()
        let req = try client.request(path: "running-workouts", queryItems: [
            URLQueryItem(name: "date", value: formatter.string(from: date))
        ])
        let res: DayRunningRecordsResponse = try await client.execute(req)
        return res.records
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord {
        struct Request: Encodable {
            let workoutDate: String
            let durationMinutes: Int
            let distanceKm: Double
            let source: String
        }

        let formatter = WorkoutDateFormatter()
        let req = try client.request(
            method: "POST",
            path: "running-workouts",
            body: Request(
                workoutDate: formatter.string(from: workoutDate),
                durationMinutes: durationMinutes,
                distanceKm: distanceKm,
                source: source.rawValue
            )
        )
        return try await client.execute(req)
    }
}

// MARK: - Mock Implementation

final class MockWorkoutService: WorkoutServiceProtocol {
    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise {
        try await Task.sleep(nanoseconds: 200_000_000)
        return Exercise(id: exerciseId, name: name, sets: MockData.benchPress.sets)
    }

    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        try await Task.sleep(nanoseconds: 200_000_000)
        return ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps, rpe: nil)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        try await Task.sleep(nanoseconds: 200_000_000)
        return ExerciseSet(id: UUID().uuidString, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps, rpe: nil)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func deleteExercise(sessionId: String, exerciseId: String) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        try await Task.sleep(nanoseconds: 200_000_000)
        return ExerciseSet(id: setId, setIndex: 1, weight: 60, weightUnit: .kg, reps: 8, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        var components = DateComponents()
        components.year = year
        components.month = month
        // Return a few sample active days
        let days = [3, 8, 10, 14, 17, 18, 21]
        return days.compactMap { day -> Date? in
            components.day = day
            return calendar.date(from: components)
        }
    }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        let now = Date()
        return [
            WorkoutSession(
                id: "sess-1",
                userId: "user-1",
                date: date,
                durationMinutes: 30,
                label: "Pull Day",
                exercises: [MockData.deadlift],
                createdAt: now,
                updatedAt: now
            )
        ]
    }

    func activeRunningDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        try await activeDaysInMonth(year: year, month: month)
    }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] {
        let now = Date()
        return [
            RunningWorkoutRecord(
                id: "run-1",
                userId: "user-1",
                workoutDate: date,
                durationMinutes: 30,
                distanceKm: 5,
                source: .chat,
                createdAt: now,
                updatedAt: now
            )
        ]
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord {
        try await Task.sleep(nanoseconds: 200_000_000)
        let now = Date()
        return RunningWorkoutRecord(
            id: UUID().uuidString,
            userId: "user-1",
            workoutDate: workoutDate,
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            source: source,
            createdAt: now,
            updatedAt: now
        )
    }
}
