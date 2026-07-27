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

    // MARK: - TrainingHeaderSubtitle

    /// 除 tense 外的参数默认都是「什么都没有」，每条用例只覆写自己关心的那个。
    private func subtitle(
        tense: DayTense,
        hasPlan: Bool = false,
        isLoading: Bool = false,
        hasRecord: Bool = false,
        hasRunningRecords: Bool = false,
        hasCompletedMuscles: Bool = false
    ) -> TrainingHeaderSubtitle {
        TrainingHeaderSubtitle.resolve(
            tense: tense,
            hasPlan: hasPlan,
            isLoading: isLoading,
            hasRecord: hasRecord,
            hasRunningRecords: hasRunningRecords,
            hasCompletedMuscles: hasCompletedMuscles
        )
    }

    func testTodayWithPlanShowsDateOnly() {
        XCTAssertEqual(subtitle(tense: .today, hasPlan: true), .dateOnly)
    }

    /// 有计划就不出副标题，哪怕当天还有自由记录和跑步——细节都在内容区。
    func testTodayPlanWinsOverRecordAndRunning() {
        XCTAssertEqual(
            subtitle(tense: .today, hasPlan: true, hasRecord: true, hasRunningRecords: true),
            .dateOnly
        )
    }

    /// 加载中不要先闪一行兜底文案，等计划落地再决定。
    func testTodayWhileLoadingShowsDateOnly() {
        XCTAssertEqual(subtitle(tense: .today, isLoading: true), .dateOnly)
    }

    func testTodayWithoutPlanButWithRecordIsFreeRecordDay() {
        XCTAssertEqual(subtitle(tense: .today, hasRecord: true), .freeRecordDay)
    }

    func testTodayWithOnlyRunningRecordsIsRunningOnly() {
        XCTAssertEqual(subtitle(tense: .today, hasRunningRecords: true), .runningOnly)
    }

    /// 自由记录优先于仅跑步：两者都在时算记录日。
    func testTodayRecordTakesPrecedenceOverRunning() {
        XCTAssertEqual(
            subtitle(tense: .today, hasRecord: true, hasRunningRecords: true),
            .freeRecordDay
        )
    }

    /// 空状态下内容区不渲染任何东西，这条兜底文案是当天唯一的引导，不能退化成 dateOnly。
    func testTodayWithNothingIsEmptyDay() {
        XCTAssertEqual(subtitle(tense: .today), .emptyDay)
    }

    func testPastWithCompletedMusclesShowsMuscles() {
        XCTAssertEqual(subtitle(tense: .past, hasCompletedMuscles: true), .completedMuscles)
    }

    func testPastWithoutCompletedMusclesShowsDateOnly() {
        XCTAssertEqual(subtitle(tense: .past), .dateOnly)
    }

    /// 未来日的计划细节由内容区承载，头部一律只留日期。
    func testFutureAlwaysShowsDateOnly() {
        for tense in [DayTense.futureInPlanWeek, .futureBeyondPlan] {
            XCTAssertEqual(subtitle(tense: tense, hasPlan: true), .dateOnly, "unexpected for \(tense)")
            XCTAssertEqual(subtitle(tense: tense), .dateOnly, "unexpected for \(tense)")
        }
    }
}
