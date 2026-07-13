import XCTest
@testable import PeakLog

/// Issue #55: `currentWeekDays()` / `calendarDays()` (via `hasWorkout(on:)`)
/// used to construct a brand new `WorkoutDateFormatter()` — a fresh
/// `Calendar` + `DateFormatter` — on every single call, including once per
/// day while building a 42-cell month grid. `WorkoutDateFormatter` is now
/// cached as a lazy instance property. This test exercises `hasWorkout`
/// across a full month grid and the current week through the cached
/// formatter, pinning that the date-string matching still behaves
/// correctly (the real regression risk of switching to a shared instance).
@MainActor
final class HistoryViewModelFormatterCacheTests: XCTestCase {
    private var databaseFileURL: URL!
    private var database: LocalAppDatabase!
    private var viewModel: HistoryViewModel!

    override func setUp() {
        super.setUp()
        databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-formatter-cache-tests-\(UUID().uuidString).json")
        database = LocalAppDatabase(fileURL: databaseFileURL)
        viewModel = HistoryViewModel(
            workoutService: LocalWorkoutService(database: database),
            trainingPlanService: LocalTrainingPlanService(database: database)
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: databaseFileURL)
        super.tearDown()
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
    }
}
