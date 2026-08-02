import XCTest
@testable import PeakLog

/// Issue #8: `onAppear()` used to guard on `todayPlan == nil, todayRecord ==
/// nil, runningRecords.isEmpty` and skip the reload otherwise. Once any of
/// those three was non-empty (e.g. the seeded plan loads on first appear),
/// switching tabs away and back never refreshed again — new data written
/// while the screen was away stayed invisible until some other code path
/// happened to call `refresh()` directly.
@MainActor
final class TodayWorkoutOnAppearRefreshTests: XCTestCase {
    private var databaseFileURL: URL!
    private var database: LocalAppDatabase!
    private var viewModel: TodayWorkoutViewModel!
    private var defaults: UserDefaults!
    private let suiteName = "TodayWorkoutOnAppearRefreshTests"

    // `setUp()`/`tearDown()` are the `async throws` variants, not the sync ones:
    // the sync overrides are nonisolated on `XCTestCase`, so a `@MainActor` test
    // case cannot touch its own main-actor properties in them under the Swift 6
    // language mode. The async variants may carry the class's isolation
    // (issue #137).
    override func setUp() async throws {
        try await super.setUp()
        databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("today-onappear-refresh-tests-\(UUID().uuidString).json")
        database = LocalAppDatabase(fileURL: databaseFileURL)
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        viewModel = TodayWorkoutViewModel(
            trainingPlanService: LocalTrainingPlanService(database: database),
            workoutService: LocalWorkoutService(database: database),
            liveActivityManager: NoOpPlanLiveActivityManager(),
            sessionDefaults: defaults
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: databaseFileURL)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // Simulates "switch tab away, add data elsewhere, switch tab back":
    // a second onAppear() must pick up the running record added after the
    // first appear, instead of being blocked by the old non-empty guard.
    func testOnAppearRefreshesAfterReturningToScreen() async throws {
        await viewModel.onAppear()
        XCTAssertTrue(viewModel.runningRecords.isEmpty, "precondition: no running record yet")

        _ = try await database.createRunningRecord(
            workoutDate: Date(),
            durationMinutes: 25,
            distanceKm: 5,
            source: .manual
        )

        // Re-entering the screen (a second .task firing) must reload, not
        // early-return because todayPlan is already non-nil from the seed.
        await viewModel.onAppear()

        XCTAssertEqual(viewModel.runningRecords.count, 1, "returning to the screen should surface data written while away")
    }

    // A "partially loaded" state (plan present, but record/runningRecords
    // still nil/empty because the day genuinely has neither yet) must not
    // get stuck: once a record appears server/local-side, coming back to
    // the screen should show it.
    func testOnAppearRefreshesWhenOnlyPlanWasPreviouslyNonEmpty() async throws {
        await viewModel.onAppear()
        XCTAssertNotNil(viewModel.todayPlan, "precondition: seed data includes a today plan")
        XCTAssertNil(viewModel.todayRecord)
        XCTAssertTrue(viewModel.runningRecords.isEmpty)

        _ = try await database.createRunningRecord(
            workoutDate: Date(),
            durationMinutes: 10,
            distanceKm: 2,
            source: .manual
        )

        await viewModel.onAppear()

        XCTAssertEqual(viewModel.runningRecords.count, 1)
    }

    // Regression for the "flashes back to a spinner" bug: once the screen
    // has successfully loaded once, a later onAppear()-triggered refresh
    // (e.g. revisiting the tab) must not toggle `isLoading` back to true —
    // TodayWorkoutScreen swaps its entire body for a bare ProgressView while
    // isLoading is true, so doing that on every revisit would wipe already
    // -rendered content back to a spinner instead of updating in place.
    func testRevisitingAfterInitialLoadDoesNotToggleIsLoadingBackOn() async throws {
        let delayNanos: UInt64 = 150_000_000 // 150ms: long enough to observe mid-flight state
        let services = DelayedTodayWorkoutFakeServices(delayNanos: delayNanos)
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: services,
            workoutService: services,
            liveActivityManager: NoOpPlanLiveActivityManager(),
            sessionDefaults: defaults
        )

        XCTAssertFalse(viewModel.hasLoadedOnce, "precondition: nothing loaded yet")

        // First load: the full-page spinner is expected while in flight.
        let initialLoad = Task { await viewModel.onAppear() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(viewModel.isLoading, "first load should show the full-page spinner while in flight")
        await initialLoad.value
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.hasLoadedOnce)
        XCTAssertNotNil(viewModel.todayPlan, "precondition: first load produced content")

        // Revisit: a second round trip is in flight, but isLoading must stay
        // false throughout so the already-rendered plan stays on screen
        // instead of being replaced by ProgressView.
        let revisit = Task { await viewModel.onAppear() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(viewModel.isLoading, "revisiting after a successful load must not flash the page back to a spinner")
        XCTAssertNotNil(viewModel.todayPlan, "existing content must remain rendered during a background refresh")
        await revisit.value
        XCTAssertFalse(viewModel.isLoading)
    }
}

/// Minimal fake conforming to both service protocols `TodayWorkoutViewModel`
/// needs, with a configurable delay on the three calls `refresh()` makes so
/// tests can observe `isLoading` mid-flight.
private final class DelayedTodayWorkoutFakeServices: TrainingPlanServiceProtocol, WorkoutServiceProtocol {
    let delayNanos: UInt64

    init(delayNanos: UInt64) {
        self.delayNanos = delayNanos
    }

    // MARK: TrainingPlanServiceProtocol
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        try await Task.sleep(nanoseconds: delayNanos)
        return TrainingPlanDay(
            id: "delayed-plan-day",
            planDate: "2026-07-13",
            dayIndex: 1,
            title: "Delayed Day",
            focus: nil,
            status: "planned",
            exercises: []
        )
    }

    func completePlannedSet(planSetId: String, actualWeight: Double?, actualWeightUnit: WeightUnit, actualReps: Int) async throws -> TrainingPlanSet {
        fatalError("unused")
    }
    func updatePlannedSet(planSetId: String, targetWeight: Double?, targetWeightUnit: WeightUnit, targetReps: Int) async throws -> TrainingPlanSet {
        fatalError("unused")
    }
    func addPlannedSet(planExerciseId: String, targetWeight: Double?, targetWeightUnit: WeightUnit, targetReps: Int) async throws -> TrainingPlanSet {
        fatalError("unused")
    }
    func deletePlannedSet(planSetId: String) async throws {}
    func deletePlannedExercise(planExerciseId: String) async throws {}
    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay { fatalError("unused") }
    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay { fatalError("unused") }

    // MARK: WorkoutServiceProtocol
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
        try await Task.sleep(nanoseconds: delayNanos)
        return []
    }
    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] {
        try await Task.sleep(nanoseconds: delayNanos)
        return []
    }
    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession { fatalError("unused") }
    func createRunningRecord(workoutDate: Date, durationMinutes: Int, distanceKm: Double, source: RunningWorkoutSource) async throws -> RunningWorkoutRecord {
        fatalError("unused")
    }
}
