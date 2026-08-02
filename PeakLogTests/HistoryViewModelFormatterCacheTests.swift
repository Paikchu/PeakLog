import XCTest
@testable import PeakLog

/// Issue #55: `currentWeekDays()` / `calendarDays()` (via `hasWorkout(on:)`)
/// used to construct a brand new `WorkoutDateFormatter()` — a fresh
/// `Calendar` + `DateFormatter` — on every single call, including once per
/// day while building a 42-cell month grid. `WorkoutDateFormatter` is now
/// cached as a lazy instance property.
///
/// Caching the *wrapper* alone doesn't fix the perf issue if the wrapper's
/// `string(from:)`/`date(from:)` still builds a fresh `DateFormatter` on
/// every call (which is what the original struct-based `WorkoutDateFormatter`
/// did) — so `WorkoutDateFormatter` itself was changed from a struct to a
/// class that lazily builds its `DateFormatter` once and reuses it. This
/// test exercises `hasWorkout` across a full month grid and the current
/// week through the cached formatter, pinning both that date-string
/// matching still behaves correctly and that the underlying `DateFormatter`
/// is actually constructed ~once instead of once per cell.
@MainActor
final class HistoryViewModelFormatterCacheTests: XCTestCase {
    private var databaseFileURL: URL!
    private var database: LocalAppDatabase!
    private var viewModel: HistoryViewModel!

    // `setUp()`/`tearDown()` are the `async throws` variants, not the sync ones:
    // the sync overrides are nonisolated on `XCTestCase`, so a `@MainActor` test
    // case cannot touch its own main-actor properties in them under the Swift 6
    // language mode. The async variants may carry the class's isolation
    // (issue #137).
    override func setUp() async throws {
        try await super.setUp()
        databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-formatter-cache-tests-\(UUID().uuidString).json")
        database = LocalAppDatabase(fileURL: databaseFileURL)
        viewModel = HistoryViewModel(
            workoutService: LocalWorkoutService(database: database),
            trainingPlanService: LocalTrainingPlanService(database: database)
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: databaseFileURL)
        try await super.tearDown()
    }

    func testCalendarDaysAndWeekDaysMarkTodayAsWorkedOutAfterLoadCalendar() async throws {
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Formatter Cache Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Cache Curl",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 20, weightUnit: .kg, reps: 10, rpe: nil)]
                )
            ]
        ))

        await viewModel.loadCalendar()

        // Baseline after loadCalendar() (which itself does one string(from:)
        // per active day) so the assertion below only counts constructions
        // triggered by the grid/week rendering that follows.
        let constructionsBeforeRendering = WorkoutDateFormatter.formatterConstructionCount

        let monthGrid = viewModel.calendarDays()
        let todayCell = try XCTUnwrap(monthGrid.first { $0.isToday })
        XCTAssertTrue(todayCell.hasWorkout, "today's cell should be marked worked-out after loadCalendar()")

        // Sanity check the grid is fully populated (exercises hasWorkout via
        // the cached formatter for every one of the 42 cells, not just the
        // first call).
        XCTAssertEqual(monthGrid.count, 42)

        let weekDays = viewModel.currentWeekDays()
        let todayInWeek = try XCTUnwrap(weekDays.first { $0.isToday })
        XCTAssertTrue(todayInWeek.hasWorkout, "today's cell in the week strip should also be marked worked-out")

        // The real regression check: rendering the 42-cell month grid plus
        // the 7-cell week strip (49 `hasWorkout` calls, each formatting a
        // date) must not construct a new `DateFormatter` per call. Both the
        // `WorkoutDateFormatter` wrapper (cached on the view model) and,
        // after this fix, the `DateFormatter` it owns are reused, so no new
        // construction should happen at all here.
        XCTAssertEqual(
            WorkoutDateFormatter.formatterConstructionCount,
            constructionsBeforeRendering,
            "rendering the month grid + week strip should not construct any new DateFormatter — the cached one must be reused across all 49 hasWorkout(on:) calls"
        )
    }

    // Directly pins the cache: repeated string(from:) calls on one
    // WorkoutDateFormatter instance must only construct the underlying
    // DateFormatter once, not once per call — this is the actual bug from
    // review (the struct wrapper was cached, but its `makeFormatter()`
    // still ran on every `string(from:)`/`date(from:)` call).
    func testWorkoutDateFormatterConstructsUnderlyingDateFormatterOnce() {
        let formatter = WorkoutDateFormatter()
        let before = WorkoutDateFormatter.formatterConstructionCount

        for offset in 0..<42 {
            _ = formatter.string(from: Date().addingTimeInterval(TimeInterval(offset) * 86_400))
        }

        XCTAssertEqual(
            WorkoutDateFormatter.formatterConstructionCount,
            before + 1,
            "42 string(from:) calls on the same instance should construct the underlying DateFormatter exactly once"
        )
    }
}
