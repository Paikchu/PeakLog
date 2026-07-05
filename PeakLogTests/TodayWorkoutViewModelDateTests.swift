import XCTest
@testable import PeakLog

final class TodayWorkoutViewModelDateTests: XCTestCase {
    @MainActor
    func testCurrentPlanDateStringUsesLocalTimeZoneInsteadOfUTC() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = WorkoutDateFormatter(timeZone: shanghai)
        let date = Date(timeIntervalSince1970: 1_775_232_600) // 2026-04-03 16:10:00 UTC = 2026-04-04 00:10:00 +0800

        let planDate = TodayWorkoutViewModel.currentPlanDateString(
            now: date,
            formatter: formatter
        )

        XCTAssertEqual(planDate, "2026-04-04")
    }
}
