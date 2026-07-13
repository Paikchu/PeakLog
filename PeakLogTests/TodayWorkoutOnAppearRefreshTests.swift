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

    override func setUp() {
        super.setUp()
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

    override func tearDown() {
        try? FileManager.default.removeItem(at: databaseFileURL)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
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
}
