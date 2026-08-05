import XCTest
@testable import PeakLog

final class PreviousPerformanceTextTests: XCTestCase {
    private func set(_ index: Int, weight: Double?, unit: WeightUnit = .kg, reps: Int) -> ExerciseSet {
        ExerciseSet(id: "s\(index)", setIndex: index, weight: weight, weightUnit: unit, reps: reps)
    }

    func testEmptyHistoryHasNoSummary() {
        XCTAssertNil(PreviousPerformanceText.summary(from: []))
    }

    func testUniformSetsCollapseIntoSetCount() {
        let sets = [
            set(1, weight: 60, reps: 8),
            set(2, weight: 60, reps: 8),
            set(3, weight: 60, reps: 8)
        ]
        XCTAssertEqual(PreviousPerformanceText.summary(from: sets), "60 kg × 8 × 3")
    }

    func testSingleSetOmitsTheCountSuffix() {
        XCTAssertEqual(PreviousPerformanceText.summary(from: [set(1, weight: 60, reps: 8)]), "60 kg × 8")
    }

    func testVaryingSetsAreListedWithUnitOnlyOnce() {
        let sets = [
            set(1, weight: 60, reps: 8),
            set(2, weight: 60, reps: 7),
            set(3, weight: 57.5, reps: 6)
        ]
        XCTAssertEqual(PreviousPerformanceText.summary(from: sets), "60 kg × 8, 60 × 7, 57.5 × 6")
    }

    func testLongSetListIsTruncatedWithOverflowMarker() {
        let sets = [
            set(1, weight: 60, reps: 10),
            set(2, weight: 60, reps: 9),
            set(3, weight: 60, reps: 8),
            set(4, weight: 60, reps: 7),
            set(5, weight: 60, reps: 6),
            set(6, weight: 60, reps: 5)
        ]
        XCTAssertEqual(
            PreviousPerformanceText.summary(from: sets),
            "60 kg × 10, 60 × 9, 60 × 8, 60 × 7 +2"
        )
    }

    func testOutOfOrderSetsAreSortedBySetIndex() {
        let sets = [
            set(3, weight: 50, reps: 6),
            set(1, weight: 60, reps: 8),
            set(2, weight: 55, reps: 7)
        ]
        XCTAssertEqual(PreviousPerformanceText.summary(from: sets), "60 kg × 8, 55 × 7, 50 × 6")
    }

    func testBodyweightSetsRenderRepsOnly() {
        let sets = [set(1, weight: nil, reps: 12), set(2, weight: nil, reps: 10)]
        XCTAssertEqual(PreviousPerformanceText.summary(from: sets), "× 12, × 10")
    }

    func testWholeNumberWeightsDropTheDecimal() {
        XCTAssertEqual(PreviousPerformanceText.summary(from: [set(1, weight: 62.0, reps: 5)]), "62 kg × 5")
        XCTAssertEqual(PreviousPerformanceText.summary(from: [set(1, weight: 62.5, reps: 5)]), "62.5 kg × 5")
    }

    func testPoundsUnitIsPreserved() {
        let sets = [set(1, weight: 135, unit: .lbs, reps: 5), set(2, weight: 135, unit: .lbs, reps: 5)]
        XCTAssertEqual(PreviousPerformanceText.summary(from: sets), "135 lbs × 5 × 2")
    }
}
