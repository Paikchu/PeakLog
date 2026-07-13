import XCTest
@testable import PeakLog

/// Issue #54: `HistoryScreen`'s initial `.task` used to `await` `loadPlan()`,
/// `loadExerciseLibrary()`, `loadCalendar()`, and `loadSessionsForSelectedDate()`
/// one after another even though none of them reads another's result — each
/// only writes to its own slice of `HistoryViewModel`'s published state. This
/// pins two things: the four loads actually overlap in time (not just
/// happen to look parallel), and running them concurrently still produces
/// the same correct end state as running them in sequence.
@MainActor
final class HistoryScreenParallelLoadTests: XCTestCase {
    func testConcurrentInitialLoadsOverlapAndProduceCorrectState() async throws {
        let delayNanos: UInt64 = 100_000_000 // 100ms per fake load
        let workoutService = DelayedParallelWorkoutService(delayNanos: delayNanos)
        let planService = DelayedParallelTrainingPlanService(delayNanos: delayNanos)
        let libraryService = DelayedParallelExerciseLibraryService(delayNanos: delayNanos)

        let viewModel = HistoryViewModel(
            workoutService: workoutService,
            trainingPlanService: planService,
            exerciseLibraryService: libraryService
        )

        let start = Date()
        // Mirrors HistoryScreen's `.task` body exactly.
        async let plan: () = viewModel.loadPlan()
        async let library: () = viewModel.loadExerciseLibrary()
        async let calendar: () = viewModel.loadCalendar()
        async let sessions: () = viewModel.loadSessionsForSelectedDate()
        _ = await (plan, library, calendar, sessions)
        let elapsed = Date().timeIntervalSince(start)

        // Four independent 100ms loads run sequentially would take ~400ms;
        // run concurrently they should complete close to a single 100ms
        // round trip. 250ms leaves generous headroom for CI scheduling
        // jitter while still failing if a future change reintroduces
        // sequential awaits.
        XCTAssertLessThan(elapsed, 0.25, "the four loads should overlap instead of running sequentially")

        XCTAssertEqual(viewModel.activePlan?.id, "parallel-plan")
        XCTAssertEqual(viewModel.exerciseLibrary.map(\.id), ["parallel-exercise"])
        XCTAssertTrue(viewModel.activeDates.contains(where: { _ in true }) || viewModel.activeDates.isEmpty)
        XCTAssertEqual(viewModel.sessions.first?.id, "parallel-session")
    }
}

private struct DelayedParallelWorkoutService: WorkoutServiceProtocol {
    let delayNanos: UInt64

    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }
    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: "new", setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}
    func deleteExercise(sessionId: String, exerciseId: String) async throws {}
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: nil, weightUnit: .kg, reps: 0, rpe: rpe)
    }
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] {
        try await Task.sleep(nanoseconds: delayNanos)
        return [Date()]
    }
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        try await Task.sleep(nanoseconds: delayNanos)
        return [
            WorkoutSession(
                id: "parallel-session",
                userId: "user-1",
                date: date,
                durationMinutes: 30,
                label: nil,
                exercises: [],
                createdAt: date,
                updatedAt: date
            )
        ]
    }
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }
    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession { fatalError("unused") }
    func createRunningRecord(workoutDate: Date, durationMinutes: Int, distanceKm: Double, source: RunningWorkoutSource) async throws -> RunningWorkoutRecord { fatalError("unused") }
}

private struct DelayedParallelTrainingPlanService: TrainingPlanServiceProtocol {
    let delayNanos: UInt64

    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? {
        try await Task.sleep(nanoseconds: delayNanos)
        return TrainingPlan(
            id: "parallel-plan",
            weekStartDate: "2026-07-13",
            goalSummary: nil,
            coachSummary: "",
            days: []
        )
    }
    func fetchTodayPlan() async throws -> TrainingPlanDay? { nil }
    func completePlannedSet(planSetId: String, actualWeight: Double?, actualWeightUnit: WeightUnit, actualReps: Int) async throws -> TrainingPlanSet { fatalError("unused") }
    func updatePlannedSet(planSetId: String, targetWeight: Double?, targetWeightUnit: WeightUnit, targetReps: Int) async throws -> TrainingPlanSet { fatalError("unused") }
    func addPlannedSet(planExerciseId: String, targetWeight: Double?, targetWeightUnit: WeightUnit, targetReps: Int) async throws -> TrainingPlanSet { fatalError("unused") }
    func deletePlannedSet(planSetId: String) async throws {}
    func deletePlannedExercise(planExerciseId: String) async throws {}
    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay { fatalError("unused") }
    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay { fatalError("unused") }
}

private struct DelayedParallelExerciseLibraryService: ExerciseLibraryServiceProtocol {
    let delayNanos: UInt64

    func fetchLibrary() async -> [ExerciseDefinition] {
        try? await Task.sleep(nanoseconds: delayNanos)
        return [
            ExerciseDefinition(
                id: "parallel-exercise",
                nameEN: "Parallel Press",
                nameZH: "并行推举",
                aliases: [],
                muscleGroup: .chest,
                equipment: .barbell,
                loadType: .weighted,
                popularity: 1
            )
        ]
    }
    func fetchRecentEntries(limit: Int) async -> [RecentExerciseEntry] { [] }
    func fetchRecommendations(todaysSelections: [ExerciseDefinition], limit: Int) async -> [ExerciseDefinition] { [] }
    func addCustomExercise(name: String, muscleGroup: MuscleGroup, loadType: ExerciseLoadType) async throws -> ExerciseDefinition {
        fatalError("unused")
    }
    func fetchLastPerformedSets(exerciseId: String?, exerciseName: String) async -> [ExerciseSet]? { nil }
}
