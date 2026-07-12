import XCTest
@testable import PeakLog

@MainActor
final class HistoryStaleResultTests: XCTestCase {
    func testStaleDateResultCannotOverwriteNewerSelection() async throws {
        let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let dateA = formatter.date(from: "2026-08-09")!
        let dateB = formatter.date(from: "2026-08-10")!
        let service = DelayedHistoryWorkoutService(
            sessionsByDay: [
                "2026-08-09": [makeSession(id: "stale-a", date: dateA, name: "旧日期")],
                "2026-08-10": [makeSession(id: "fresh-b", date: dateB, name: "新日期")]
            ],
            delaysByDay: ["2026-08-09": 200_000_000]
        )
        let viewModel = HistoryViewModel(
            workoutService: service,
            trainingPlanService: EmptyHistoryTrainingPlanService()
        )

        viewModel.selectDate(dateA)
        let staleTask = Task { @MainActor in await viewModel.loadSessionsForSelectedDate() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let freshTask = Task { @MainActor in await viewModel.selectDateAndRefresh(dateB) }
        await freshTask.value
        await staleTask.value

        XCTAssertEqual(formatter.string(from: viewModel.selectedDate), "2026-08-10")
        XCTAssertEqual(viewModel.sessions.first?.exercises.first?.name, "新日期")
    }

    private func makeSession(id: String, date: Date, name: String) -> WorkoutSession {
        WorkoutSession(
            id: id,
            userId: "user-1",
            date: date,
            durationMinutes: 30,
            label: nil,
            exercises: [Exercise(id: "\(id)-exercise", name: name, sets: [])],
            createdAt: date,
            updatedAt: date
        )
    }
}

private struct DelayedHistoryWorkoutService: WorkoutServiceProtocol {
    let sessionsByDay: [String: [WorkoutSession]]
    let delaysByDay: [String: UInt64]
    let formatter = WorkoutDateFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)

    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet { ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps) }
    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet { ExerciseSet(id: "new", setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps) }
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}
    func deleteExercise(sessionId: String, exerciseId: String) async throws {}
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet { ExerciseSet(id: setId, setIndex: 1, weight: nil, weightUnit: .kg, reps: 0, rpe: rpe) }
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        let key = formatter.string(from: date)
        if let delay = delaysByDay[key] { try await Task.sleep(nanoseconds: delay) }
        return sessionsByDay[key] ?? []
    }
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }
    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession { fatalError("unused") }
    func createRunningRecord(workoutDate: Date, durationMinutes: Int, distanceKm: Double, source: RunningWorkoutSource) async throws -> RunningWorkoutRecord { fatalError("unused") }
}

private struct EmptyHistoryTrainingPlanService: TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }
    func fetchTodayPlan() async throws -> TrainingPlanDay? { nil }
    func completePlannedSet(planSetId: String, actualWeight: Double?, actualWeightUnit: WeightUnit, actualReps: Int) async throws -> TrainingPlanSet { fatalError("unused") }
    func updatePlannedSet(planSetId: String, targetWeight: Double?, targetWeightUnit: WeightUnit, targetReps: Int) async throws -> TrainingPlanSet { fatalError("unused") }
    func addPlannedSet(planExerciseId: String, targetWeight: Double?, targetWeightUnit: WeightUnit, targetReps: Int) async throws -> TrainingPlanSet { fatalError("unused") }
    func deletePlannedSet(planSetId: String) async throws {}
    func deletePlannedExercise(planExerciseId: String) async throws {}
    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay { fatalError("unused") }
    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay { fatalError("unused") }
}
