import Foundation

@main
struct HistoryRunningViewModelTestRunner {
    static func main() async {
        await loadsMultipleRunningRecordsForSelectedDay()
        print("history_running_view_model_test passed")
    }

    @MainActor
    private static func loadsMultipleRunningRecordsForSelectedDay() async {
        let formatter = WorkoutDateFormatter()
        let targetDate = formatter.date(from: "2026-04-01") ?? Date()
        let records = [
            RunningWorkoutRecord(
                id: "run-1",
                userId: "user-1",
                workoutDate: targetDate,
                durationMinutes: 30,
                distanceKm: 5,
                source: .agent,
                createdAt: targetDate.addingTimeInterval(3600),
                updatedAt: targetDate.addingTimeInterval(3600)
            ),
            RunningWorkoutRecord(
                id: "run-2",
                userId: "user-1",
                workoutDate: targetDate,
                durationMinutes: 20,
                distanceKm: 3.2,
                source: .manual,
                createdAt: targetDate.addingTimeInterval(7200),
                updatedAt: targetDate.addingTimeInterval(7200)
            ),
        ]

        let viewModel = HistoryViewModel(
            workoutService: HistoryRunningWorkoutService(records: records),
            trainingPlanService: LocalTrainingPlanService(database: .shared)
        )
        viewModel.selectDate(targetDate)
        await viewModel.loadSessionsForSelectedDate()

        precondition(viewModel.runningRecords.count == 2, "Expected both running records to load")
        precondition(viewModel.runningRecords[0].id == "run-1", "Expected records to keep ascending created order")
        precondition(viewModel.sessions.isEmpty, "Expected legacy strength sessions to stay empty for running-only mode")
    }
}

private struct HistoryRunningWorkoutService: WorkoutServiceProtocol {
    let records: [RunningWorkoutRecord]
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: setId(), setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}

    func deleteExercise(sessionId: String, exerciseId: String) async throws {}

    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: nil, weightUnit: .kg, reps: 0, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        records.map(\.workoutDate)
    }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] { [] }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] {
        records
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord {
        RunningWorkoutRecord(
            id: setId(),
            userId: "user-1",
            workoutDate: workoutDate,
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            source: source,
            createdAt: workoutDate,
            updatedAt: workoutDate
        )
    }

    private func setId() -> String {
        UUID().uuidString
    }
}
