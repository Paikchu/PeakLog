import XCTest
@testable import PeakLog

/// 训练中 `+` / `−` 的取值规则。这套规则同时被专注卡片（算下一档）和
/// `TodayWorkoutViewModel`（落库前钳制）使用，两边一旦不一致，用户按下去看到的数
/// 和真正记进训练里的数就会分叉——所以规则本身要有独立的断言。
final class QuickSetAdjustmentTests: XCTestCase {
    func testWeightStepFollowsTheUnitsSmallestPracticalPlate() {
        XCTAssertEqual(QuickSetAdjustment.weightStep(for: .kg), 2.5)
        XCTAssertEqual(QuickSetAdjustment.weightStep(for: .lbs), 5)
    }

    func testWeightStepsUpAndDownInTheUnitsIncrement() {
        XCTAssertEqual(
            QuickSetAdjustment.adjustedWeight(60, steps: 1, unit: .kg, allowsUnset: false),
            62.5
        )
        XCTAssertEqual(
            QuickSetAdjustment.adjustedWeight(60, steps: -1, unit: .kg, allowsUnset: false),
            57.5
        )
        XCTAssertEqual(
            QuickSetAdjustment.adjustedWeight(135, steps: 1, unit: .lbs, allowsUnset: false),
            140
        )
    }

    /// 自重动作：nil＝纯自重。第一次 `+` 要变成"自重 +2.5kg"，减回 0 要回到 nil，
    /// 否则用户永远回不到"就用自重做"这个状态。
    func testBodyweightSetsToggleBetweenUnsetAndAddedWeight() {
        XCTAssertEqual(
            QuickSetAdjustment.adjustedWeight(nil, steps: 1, unit: .kg, allowsUnset: true),
            2.5
        )
        XCTAssertNil(QuickSetAdjustment.adjustedWeight(2.5, steps: -1, unit: .kg, allowsUnset: true))
        XCTAssertNil(QuickSetAdjustment.adjustedWeight(nil, steps: -1, unit: .kg, allowsUnset: true))
    }

    /// 非自重动作的 0 是有意义的（空杆、助力器械），不该被吞成"未设置"，
    /// 也不该继续往负数走。
    func testWeightedSetsFloorAtZeroInsteadOfUnsetting() {
        XCTAssertEqual(
            QuickSetAdjustment.adjustedWeight(2.5, steps: -1, unit: .kg, allowsUnset: false),
            0
        )
        XCTAssertEqual(
            QuickSetAdjustment.adjustedWeight(0, steps: -1, unit: .kg, allowsUnset: false),
            0
        )
    }

    /// 训练中会连点很多下，浮点累加不能漂：加 8 下再减 8 下必须**精确**回到起点，
    /// 否则 60 会变成 60.000000000000014，显示成 "60.0"。
    func testRepeatedStepsDoNotAccumulateFloatingPointDrift() {
        var weight: Double? = 60
        for _ in 0..<8 {
            weight = QuickSetAdjustment.adjustedWeight(weight, steps: 1, unit: .kg, allowsUnset: false)
        }
        XCTAssertEqual(weight, 80)
        for _ in 0..<8 {
            weight = QuickSetAdjustment.adjustedWeight(weight, steps: -1, unit: .kg, allowsUnset: false)
        }
        XCTAssertEqual(weight, 60)
    }

    /// 轮盘的最小刻度是 0.25，快速调整必须落在同一张网格上，
    /// 不然会出现"点出来的值在轮盘里选不中"。
    func testAdjustedWeightSnapsToTheWheelsQuarterGrid() {
        let adjusted = QuickSetAdjustment.adjustedWeight(60.1, steps: 1, unit: .kg, allowsUnset: false)
        XCTAssertEqual(adjusted, 62.5)
    }

    func testRepsStepByOneAndNeverReachZero() {
        XCTAssertEqual(QuickSetAdjustment.adjustedReps(6, steps: 1), 7)
        XCTAssertEqual(QuickSetAdjustment.adjustedReps(6, steps: -1), 5)
        XCTAssertEqual(QuickSetAdjustment.adjustedReps(1, steps: -1), 1)
    }

    func testClampsGuardTheViewModelEntryPoint() {
        XCTAssertEqual(QuickSetAdjustment.clampedWeight(-5), 0)
        XCTAssertNil(QuickSetAdjustment.clampedWeight(nil))
        XCTAssertEqual(QuickSetAdjustment.clampedWeight(62.5), 62.5)
        XCTAssertEqual(QuickSetAdjustment.clampedReps(0), 1)
        XCTAssertEqual(QuickSetAdjustment.clampedReps(-3), 1)
        XCTAssertEqual(QuickSetAdjustment.clampedReps(8), 8)
    }
}
