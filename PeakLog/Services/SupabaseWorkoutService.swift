import Foundation
import Supabase

// MARK: - SupabaseWorkoutService

final class SupabaseWorkoutService: WorkoutServiceProtocol {
    private let supabase = SupabaseManager.shared.client

    // MARK: - Exercise editing

    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise {
        struct ExerciseRow: Decodable {
            let id: String
            let name: String
        }

        let rows: [ExerciseRow] = try await supabase
            .from("exercises")
            .update(["name": name])
            .eq("id", value: exerciseId)
            .is("deleted_at", value: nil)
            .select("id, name")
            .execute()
            .value

        guard let row = rows.first else { throw APIError.notFound }
        return Exercise(id: row.id, name: row.name, sets: [])
    }

    func updateSet(
        sessionId: String,
        exerciseId: String,
        setId: String,
        weight: Double,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet {
        struct SetRow: Decodable {
            let id: String
            let setIndex: Int
            let weight: Double?
            let weightUnit: String
            let reps: Int?
            enum CodingKeys: String, CodingKey {
                case id
                case setIndex = "set_index"
                case weight
                case weightUnit = "weight_unit"
                case reps
            }
        }

        let rows: [SetRow] = try await supabase
            .from("exercise_sets")
            .update([
                "weight": AnyJSON(weight),
                "weight_unit": AnyJSON(weightUnit.rawValue),
                "reps": AnyJSON(reps)
            ])
            .eq("id", value: setId)
            .is("deleted_at", value: nil)
            .select()
            .execute()
            .value

        guard let row = rows.first else { throw APIError.notFound }
        return ExerciseSet(
            id: row.id,
            setIndex: row.setIndex,
            weight: row.weight ?? 0,
            weightUnit: WeightUnit(rawValue: row.weightUnit) ?? .kg,
            reps: row.reps ?? 0
        )
    }

    func addSet(
        sessionId: String,
        exerciseId: String,
        weight: Double,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet {
        // Get the current max set_index for this exercise
        struct MaxSetRow: Decodable {
            let setIndex: Int
            enum CodingKeys: String, CodingKey { case setIndex = "set_index" }
        }

        let existingSets: [MaxSetRow] = try await supabase
            .from("exercise_sets")
            .select("set_index")
            .eq("exercise_id", value: exerciseId)
            .is("deleted_at", value: nil)
            .order("set_index", ascending: false)
            .limit(1)
            .execute()
            .value

        let nextIndex = (existingSets.first?.setIndex ?? 0) + 1

        // Get user_id from session context
        let user = try await supabase.auth.session.user

        struct NewSetRow: Decodable {
            let id: String
            let setIndex: Int
            let weight: Double?
            let weightUnit: String
            let reps: Int?
            enum CodingKeys: String, CodingKey {
                case id
                case setIndex = "set_index"
                case weight
                case weightUnit = "weight_unit"
                case reps
            }
        }

        let rows: [NewSetRow] = try await supabase
            .from("exercise_sets")
            .insert([
                "exercise_id": AnyJSON(exerciseId),
                "user_id": AnyJSON(user.id.uuidString),
                "set_index": AnyJSON(nextIndex),
                "weight": AnyJSON(weight),
                "weight_unit": AnyJSON(weightUnit.rawValue),
                "reps": AnyJSON(reps)
            ])
            .select()
            .execute()
            .value

        guard let row = rows.first else { throw APIError.serverError(500) }
        return ExerciseSet(
            id: row.id,
            setIndex: row.setIndex,
            weight: row.weight ?? 0,
            weightUnit: WeightUnit(rawValue: row.weightUnit) ?? .kg,
            reps: row.reps ?? 0
        )
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {
        try await supabase
            .from("exercise_sets")
            .update(["deleted_at": AnyJSON(ISO8601DateFormatter().string(from: Date()))])
            .eq("id", value: setId)
            .is("deleted_at", value: nil)
            .execute()
    }

    func deleteExercise(sessionId: String, exerciseId: String) async throws {
        // Soft-delete exercise; trigger cascades to sets
        try await supabase
            .from("exercises")
            .update(["deleted_at": AnyJSON(ISO8601DateFormatter().string(from: Date()))])
            .eq("id", value: exerciseId)
            .is("deleted_at", value: nil)
            .execute()
    }

    // MARK: - History queries

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents(year: year, month: month, day: 1)
        guard let start = calendar.date(from: components) else { return [] }
        components.month = month + 1
        guard let end = calendar.date(from: components) else { return [] }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]

        struct DateRow: Decodable {
            let workoutDate: String
            enum CodingKeys: String, CodingKey { case workoutDate = "workout_date" }
        }

        let rows: [DateRow] = try await supabase
            .from("workout_sessions")
            .select("workout_date")
            .gte("workout_date", value: fmt.string(from: start))
            .lt("workout_date", value: fmt.string(from: end))
            .is("deleted_at", value: nil)
            .execute()
            .value

        let uniqueDates = Set(rows.map(\.workoutDate))
        return uniqueDates.compactMap { fmt.date(from: $0) }
    }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        let dateStr = fmt.string(from: date)

        struct SessionRow: Decodable {
            let id: String
            let userId: String
            let workoutDate: String
            let durationSeconds: Int?
            let title: String?
            let exercises: [ExerciseRow]?
            let createdAt: Date
            let updatedAt: Date

            enum CodingKeys: String, CodingKey {
                case id
                case userId = "user_id"
                case workoutDate = "workout_date"
                case durationSeconds = "duration_seconds"
                case title
                case exercises
                case createdAt = "created_at"
                case updatedAt = "updated_at"
            }
        }

        struct ExerciseRow: Decodable {
            let id: String
            let name: String
            let orderIndex: Int
            let sets: [SetRow]?
            enum CodingKeys: String, CodingKey {
                case id, name
                case orderIndex = "order_index"
                case sets = "exercise_sets"
            }
        }

        struct SetRow: Decodable {
            let id: String
            let setIndex: Int
            let weight: Double?
            let weightUnit: String
            let reps: Int?
            enum CodingKeys: String, CodingKey {
                case id
                case setIndex = "set_index"
                case weight
                case weightUnit = "weight_unit"
                case reps
            }
        }

        let rows: [SessionRow] = try await supabase
            .from("workout_sessions")
            .select("*, exercises!inner(*, exercise_sets(*))")
            .eq("workout_date", value: dateStr)
            .is("deleted_at", value: nil)
            .execute()
            .value

        let dateDecoder = ISO8601DateFormatter()
        return rows.map { row in
            let exercises = (row.exercises ?? []).map { ex in
                Exercise(
                    id: ex.id,
                    name: ex.name,
                    sets: (ex.sets ?? []).map { s in
                        ExerciseSet(
                            id: s.id,
                            setIndex: s.setIndex,
                            weight: s.weight ?? 0,
                            weightUnit: WeightUnit(rawValue: s.weightUnit) ?? .kg,
                            reps: s.reps ?? 0
                        )
                    }
                )
            }.sorted { $0.sets.first?.setIndex ?? 0 < $1.sets.first?.setIndex ?? 0 }

            return WorkoutSession(
                id: row.id,
                userId: row.userId,
                date: dateDecoder.date(from: row.workoutDate) ?? date,
                durationMinutes: row.durationSeconds.map { $0 / 60 },
                label: row.title,
                exercises: exercises,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }
    }
}
