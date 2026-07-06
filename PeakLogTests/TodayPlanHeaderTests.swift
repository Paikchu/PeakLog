import XCTest
@testable import PeakLog

final class TodayPlanHeaderTests: XCTestCase {
    private let fallback = "今日训练"

    func testMeaningfulTitleIsKeptWithFocusAsSubtitle() {
        let header = TodayPlanHeader.resolve(planTitle: "Push Strength", focus: "Chest · Shoulders", fallbackTitle: fallback)
        XCTAssertEqual(header.title, "Push Strength")
        XCTAssertEqual(header.subtitle, "Chest · Shoulders")
    }

    func testGenericEnglishTitleFallsBackToFocus() {
        let header = TodayPlanHeader.resolve(planTitle: "Custom Workout", focus: "腿部", fallbackTitle: fallback)
        XCTAssertEqual(header.title, "腿部")
        XCTAssertNil(header.subtitle)
    }

    func testGenericChineseTitleFallsBackToFocus() {
        let header = TodayPlanHeader.resolve(planTitle: "自定义训练", focus: "Pull Day", fallbackTitle: fallback)
        XCTAssertEqual(header.title, "Pull Day")
        XCTAssertNil(header.subtitle)
    }

    func testGenericTitleWithoutFocusUsesFallback() {
        let header = TodayPlanHeader.resolve(planTitle: "Custom Workout", focus: nil, fallbackTitle: fallback)
        XCTAssertEqual(header.title, fallback)
        XCTAssertNil(header.subtitle)
    }

    func testEmptyTitleUsesFocusThenFallback() {
        XCTAssertEqual(
            TodayPlanHeader.resolve(planTitle: "  ", focus: "背部", fallbackTitle: fallback).title,
            "背部"
        )
        XCTAssertEqual(
            TodayPlanHeader.resolve(planTitle: nil, focus: "  ", fallbackTitle: fallback).title,
            fallback
        )
    }

    func testSubtitleOmittedWhenFocusDuplicatesTitle() {
        let header = TodayPlanHeader.resolve(planTitle: "腿部", focus: "腿部", fallbackTitle: fallback)
        XCTAssertEqual(header.title, "腿部")
        XCTAssertNil(header.subtitle)
    }

    func testEyebrowContainsDateAndWeekdayForBothLocales() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 6
        let date = Calendar(identifier: .gregorian).date(from: components)!

        let zh = TodayHeaderDateText.eyebrow(for: date, locale: Locale(identifier: "zh_CN"))
        XCTAssertTrue(zh.contains("7月6日"), "unexpected zh eyebrow: \(zh)")
        XCTAssertTrue(zh.contains("·"))

        let en = TodayHeaderDateText.eyebrow(for: date, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(en.contains("Jul 6"), "unexpected en eyebrow: \(en)")
        XCTAssertTrue(en.contains("Mon"), "unexpected en eyebrow: \(en)")
    }
}
