import Foundation
import Supabase

final class SupabaseTrainingPlanService: TrainingPlanServiceProtocol {
    private let supabase = SupabaseManager.shared.client

    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? {
        let user = try await supabase.auth.session.user
        let uid = user.id.uuidString

        struct PlanRow: Decodable {
            let id: String
            let weekStartDate: String
            let goalSnapshot: String?
            let coachSummary: String
            let days: [DayRow]?

            enum CodingKeys: String, CodingKey {
                case id
                case weekStartDate = "week_start_date"
                case goalSnapshot = "goal_snapshot"
                case coachSummary = "coach_summary"
                case days = "training_plan_days"
            }
        }

        struct DayRow: Decodable {
            let id: String
            let planDate: String
            let dayIndex: Int
            let title: String
            let focus: String?
            let status: String
            let exercises: [ExerciseRow]?

            enum CodingKeys: String, CodingKey {
                case id
                case planDate = "plan_date"
                case dayIndex = "day_index"
                case title
                case focus
                case status
                case exercises = "training_plan_exercises"
            }
        }

        struct ExerciseRow: Decodable {
            let id: String
            let orderIndex: Int
            let exerciseName: String
            let progressionMode: String
            let notes: String?
            let sets: [SetRow]?

            enum CodingKeys: String, CodingKey {
                case id
                case orderIndex = "order_index"
                case exerciseName = "exercise_name"
                case progressionMode = "progression_mode"
                case notes
                case sets = "training_plan_sets"
            }
        }

        struct SetRow: Decodable {
            let id: String
            let setIndex: Int
            let targetWeight: Double?
            let targetWeightUnit: String
            let targetReps: Int
            let completedAt: Date?
            let linkedExerciseSetId: String?

            enum CodingKeys: String, CodingKey {
                case id
                case setIndex = "set_index"
                case targetWeight = "target_weight"
                case targetWeightUnit = "target_weight_unit"
                case targetReps = "target_reps"
                case completedAt = "completed_at"
                case linkedExerciseSetId = "linked_exercise_set_id"
            }
        }

        let rows: [PlanRow] = try await supabase
            .from("training_plans")
            .select("id, week_start_date, goal_snapshot, coach_summary, training_plan_days(id, plan_date, day_index, title, focus, status, training_plan_exercises(id, order_index, exercise_name, progression_mode, notes, training_plan_sets(id, set_index, target_weight, target_weight_unit, target_reps, completed_at, linked_exercise_set_id)))")
            .eq("user_id", value: uid)
            .eq("status", value: "active")
            .order("week_start_date", ascending: false)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first else { return nil }

        return TrainingPlan(
            id: row.id,
            weekStartDate: row.weekStartDate,
            goalSummary: row.goalSnapshot,
            coachSummary: row.coachSummary,
            days: (row.days ?? []).sorted(by: { $0.dayIndex < $1.dayIndex }).map { day in
                TrainingPlanDay(
                    id: day.id,
                    planDate: day.planDate,
                    dayIndex: day.dayIndex,
                    title: day.title,
                    focus: day.focus,
                    status: day.status,
                    exercises: (day.exercises ?? []).sorted(by: { $0.orderIndex < $1.orderIndex }).map { exercise in
                        TrainingPlanExercise(
                            id: exercise.id,
                            orderIndex: exercise.orderIndex,
                            exerciseName: exercise.exerciseName,
                            progressionMode: exercise.progressionMode,
                            notes: exercise.notes,
                            sets: (exercise.sets ?? []).sorted(by: { $0.setIndex < $1.setIndex }).map { set in
                                TrainingPlanSet(
                                    id: set.id,
                                    setIndex: set.setIndex,
                                    targetWeight: set.targetWeight,
                                    targetWeightUnit: WeightUnit(rawValue: set.targetWeightUnit) ?? .kg,
                                    targetReps: set.targetReps,
                                    completedAt: set.completedAt,
                                    linkedExerciseSetId: set.linkedExerciseSetId
                                )
                            }
                        )
                    }
                )
            }
        )
    }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        guard let plan = try await fetchActiveWeeklyPlan() else { return nil }
        let formatter = WorkoutDateFormatter()
        let today = formatter.string(from: Date())
        return plan.days.first(where: { $0.planDate == today })
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet {
        let user = try await supabase.auth.session.user
        let uid = user.id.uuidString

        struct PlanSetJoinRow: Decodable {
            let id: String
            let setIndex: Int
            let linkedExerciseSetId: String?
            let planExerciseId: String
            let exercise: ExerciseJoinRow?

            enum CodingKeys: String, CodingKey {
                case id
                case setIndex = "set_index"
                case linkedExerciseSetId = "linked_exercise_set_id"
                case planExerciseId = "plan_exercise_id"
                case exercise = "training_plan_exercises"
            }
        }

        struct ExerciseJoinRow: Decodable {
            let id: String
            let exerciseName: String

            enum CodingKeys: String, CodingKey {
                case id
                case exerciseName = "exercise_name"
            }
        }

        let setRows: [PlanSetJoinRow] = try await supabase
            .from("training_plan_sets")
            .select("id, set_index, linked_exercise_set_id, plan_exercise_id, training_plan_exercises!inner(id, exercise_name)")
            .eq("id", value: planSetId)
            .eq("user_id", value: uid)
            .limit(1)
            .execute()
            .value

        guard let planSet = setRows.first, let exerciseJoin = planSet.exercise else {
            throw APIError.notFound
        }

        if planSet.linkedExerciseSetId != nil {
            return TrainingPlanSet(
                id: planSetId,
                setIndex: planSet.setIndex,
                targetWeight: actualWeight,
                targetWeightUnit: actualWeightUnit,
                targetReps: actualReps,
                completedAt: Date(),
                linkedExerciseSetId: planSet.linkedExerciseSetId
            )
        }

        let formatter = WorkoutDateFormatter()
        let today = formatter.string(from: Date())

        struct SessionRow: Decodable { let id: String }
        let existingSessions: [SessionRow] = try await supabase
            .from("workout_sessions")
            .select("id")
            .eq("user_id", value: uid)
            .eq("workout_date", value: today)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value

        let sessionId: String
        if let existingSession = existingSessions.first {
            sessionId = existingSession.id
        } else {
            let createdSessions: [SessionRow] = try await supabase
                .from("workout_sessions")
                .insert([
                    "user_id": AnyJSON(uid),
                    "workout_date": AnyJSON(today),
                    "source_type": AnyJSON("plan"),
                    "parse_status": AnyJSON("completed"),
                    "confirmation_status": AnyJSON("confirmed")
                ])
                .select("id")
                .execute()
                .value
            guard let createdSession = createdSessions.first else { throw APIError.serverError(500) }
            sessionId = createdSession.id
        }

        struct ExerciseRow: Decodable {
            let id: String
            let orderIndex: Int?
            enum CodingKeys: String, CodingKey {
                case id
                case orderIndex = "order_index"
            }
        }

        let existingExercises: [ExerciseRow] = try await supabase
            .from("exercises")
            .select("id, order_index")
            .eq("session_id", value: sessionId)
            .eq("name", value: exerciseJoin.exerciseName)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value

        let exerciseId: String
        if let existingExercise = existingExercises.first {
            exerciseId = existingExercise.id
        } else {
            let maxOrderRows: [ExerciseRow] = try await supabase
                .from("exercises")
                .select("id, order_index")
                .eq("session_id", value: sessionId)
                .is("deleted_at", value: nil)
                .order("order_index", ascending: false)
                .limit(1)
                .execute()
                .value
            let nextOrder = (maxOrderRows.first?.orderIndex ?? -1) + 1
            let createdExercises: [ExerciseRow] = try await supabase
                .from("exercises")
                .insert([
                    "session_id": AnyJSON(sessionId),
                    "user_id": AnyJSON(uid),
                    "name": AnyJSON(exerciseJoin.exerciseName),
                    "normalized_name": AnyJSON(exerciseJoin.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                    "order_index": AnyJSON(nextOrder)
                ])
                .select("id, order_index")
                .execute()
                .value
            guard let createdExercise = createdExercises.first else { throw APIError.serverError(500) }
            exerciseId = createdExercise.id
        }

        struct ExerciseSetRow: Decodable { let id: String }
        let createdSets: [ExerciseSetRow] = try await supabase
            .from("exercise_sets")
            .insert([
                "exercise_id": AnyJSON(exerciseId),
                "user_id": AnyJSON(uid),
                "set_index": AnyJSON(planSet.setIndex),
                "weight": actualWeight.map(AnyJSON.double) ?? .null,
                "weight_unit": AnyJSON(actualWeightUnit.rawValue),
                "reps": AnyJSON(actualReps)
            ])
            .select("id")
            .execute()
            .value

        guard let createdSet = createdSets.first else { throw APIError.serverError(500) }

        try await supabase
            .from("training_plan_sets")
            .update([
                "completed_at": AnyJSON(ISO8601DateFormatter().string(from: Date())),
                "linked_exercise_set_id": AnyJSON(createdSet.id)
            ])
            .eq("id", value: planSetId)
            .eq("user_id", value: uid)
            .execute()

        return TrainingPlanSet(
            id: planSetId,
            setIndex: planSet.setIndex,
            targetWeight: actualWeight,
            targetWeightUnit: actualWeightUnit,
            targetReps: actualReps,
            completedAt: Date(),
            linkedExerciseSetId: createdSet.id
        )
    }
}
