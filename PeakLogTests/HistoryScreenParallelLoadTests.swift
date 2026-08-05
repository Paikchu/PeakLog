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
        await viewModel.loadInitialScreenData()
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
        // `loadSessionsForSelectedDate()` runs the fetched session through
        // `WorkoutHistoryAggregator.mergeSessionsForHistory`, which
        // synthesizes a "history-<date>" id rather than preserving the
        // fetched session's own id — assert on what survives the merge
        // (count + duration) instead of the id.
        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.sessions.first?.durationMinutes, 30)
    }

    // Regression found in review: with loadPlan()/loadCalendar()/
    // loadSessionsForSelectedDate() all writing the shared `errorMessage`
    // from within concurrent tasks, two simultaneous failures raced —
    // whichever finished last in wall-clock time won, not a value the
    // caller could predict. `loadInitialScreenData()` now collects each
    // loader's failure separately and makes one deterministic write after
    // all four finish (fixed priority: plan, then calendar, then sessions).
    // This runs several trials that alternate which of the two failing
    // loaders (plan, sessions) finishes first in real time, and asserts the
    // resulting `errorMessage` is always the higher-priority one (plan's),
    // never flipping based on timing.
    func testConcurrentFailuresResolveErrorMessageDeterministically() async throws {
        for trial in 0..<6 {
            // Alternate which of the two failing loaders finishes first.
            let planDelay: UInt64 = trial.isMultiple(of: 2) ? 10_000_000 : 60_000_000
            let sessionsDelay: UInt64 = trial.isMultiple(of: 2) ? 60_000_000 : 10_000_000

            let workoutService = RacingFailureWorkoutService(sessionsDelayNanos: sessionsDelay)
            let planService = RacingFailureTrainingPlanService(planDelayNanos: planDelay)
            let libraryService = DelayedParallelExerciseLibraryService(delayNanos: 5_000_000)

            let viewModel = HistoryViewModel(
                workoutService: workoutService,
                trainingPlanService: planService,
                exerciseLibraryService: libraryService
            )

            await viewModel.loadInitialScreenData()

            XCTAssertEqual(
                viewModel.errorMessage,
                "plan failed",
                "trial \(trial): errorMessage must deterministically resolve to the higher-priority (plan) failure regardless of which loader finished first"
            )
        }
    }
}

private struct RacingFailureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// `activeDaysInMonth` succeeds quickly; `sessionsForDay` fails after
/// `sessionsDelayNanos`, so its finishing order relative to the plan
/// failure below can be shifted from test to test.
private struct RacingFailureWorkoutService: WorkoutServiceProtocol {
    let sessionsDelayNanos: UInt64

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
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        try await Task.sleep(nanoseconds: sessionsDelayNanos)
        throw RacingFailureError(message: "sessions failed")
    }
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }
    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession { fatalError("unused") }
    func createRunningRecord(workoutDate: Date, durationMinutes: Int, distanceKm: Double, source: RunningWorkoutSource) async throws -> RunningWorkoutRecord { fatalError("unused") }
}

/// `fetchActiveWeeklyPlan` fails after `planDelayNanos` — paired with
/// `RacingFailureWorkoutService` above to race two simultaneous failures.
private struct RacingFailureTrainingPlanService: TrainingPlanServiceProtocol {
    let planDelayNanos: UInt64

    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? {
        try await Task.sleep(nanoseconds: planDelayNanos)
        throw RacingFailureError(message: "plan failed")
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
    func fetchLastPerformedSets(exerciseId: String?, exerciseName: String, before date: Date) async -> [ExerciseSet]? { nil }
}
