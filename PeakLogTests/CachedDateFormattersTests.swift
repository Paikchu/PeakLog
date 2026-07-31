import XCTest
@testable import PeakLog

/// Issue #51 是纯重构：把各处每次调用都新建的 `DateFormatter` 换成按 locale 缓存。
/// 这里把重构前那几段 inline 构造原样抄下来当作对照实现，逐字比对输出字符串——
/// 只断言“看起来对”会漏掉 locale/格式被顺手改掉的情况。
@MainActor
final class CachedDateFormattersTests: XCTestCase {
    /// 覆盖 App 实际支持的两种语言，外加一个字段顺序不同的 locale 兜底。
    private let locales = [
        Locale(identifier: "zh_CN"),
        Locale(identifier: "en_US"),
        Locale(identifier: "en_GB"),
        Locale(identifier: "de_DE"),
    ]

    private let dates: [Date] = {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 6
        components.hour = 9
        components.minute = 30
        let calendar = Calendar(identifier: .gregorian)
        let first = calendar.date(from: components)!
        // 跨月、跨年、下午时刻，覆盖月份名和 12/24 小时制差异。
        return [
            first,
            calendar.date(byAdding: DateComponents(month: 5, hour: 8), to: first)!,
            calendar.date(byAdding: DateComponents(year: -1, day: 20), to: first)!,
        ]
    }()

    // MARK: - 输出与重构前逐字相同

    func testMediumDateShortTimeMatchesPreRefactorFormatter() {
        for locale in locales {
            for date in dates {
                let expected: String = {
                    let formatter = DateFormatter()
                    formatter.locale = locale
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    return formatter.string(from: date)
                }()
                XCTAssertEqual(
                    CachedDateFormatters.mediumDateShortTime(for: date, locale: locale),
                    expected,
                    "locale=\(locale.identifier) date=\(date)"
                )
            }
        }
    }

    func testMonthTitleMatchesPreRefactorFormatter() {
        for locale in locales {
            for date in dates {
                let expected: String = {
                    let formatter = DateFormatter()
                    formatter.locale = locale
                    formatter.dateFormat = "MMMM yyyy"
                    return formatter.string(from: date)
                }()
                XCTAssertEqual(
                    CachedDateFormatters.monthTitle(for: date, locale: locale),
                    expected,
                    "locale=\(locale.identifier) date=\(date)"
                )
            }
        }
    }

    func testDayNumberMatchesPreRefactorFormatter() {
        for locale in locales {
            for date in dates {
                let expected: String = {
                    let formatter = DateFormatter()
                    formatter.locale = locale
                    formatter.dateFormat = "d"
                    return formatter.string(from: date)
                }()
                XCTAssertEqual(
                    CachedDateFormatters.dayNumber(for: date, locale: locale),
                    expected,
                    "locale=\(locale.identifier) date=\(date)"
                )
            }
        }
    }

    func testShortStandaloneWeekdaysMatchPreRefactorFormatter() {
        for locale in locales {
            let expected: [String] = {
                let formatter = DateFormatter()
                formatter.locale = locale
                return formatter.shortStandaloneWeekdaySymbols
            }()
            XCTAssertEqual(
                CachedDateFormatters.shortStandaloneWeekdays(locale: locale),
                expected,
                "locale=\(locale.identifier)"
            )
        }
    }

    /// `TodayHeaderDateText.eyebrow` 用的两个模板：模板不同、locale 相同的两个
    /// formatter 必须各自缓存，否则会互相顶掉、输出串味。
    func testLocalizedTemplateMatchesPreRefactorFormatter() {
        for locale in locales {
            for date in dates {
                for template in ["MMMd", "EEE"] {
                    let expected: String = {
                        let formatter = DateFormatter()
                        formatter.locale = locale
                        formatter.setLocalizedDateFormatFromTemplate(template)
                        return formatter.string(from: date)
                    }()
                    XCTAssertEqual(
                        CachedDateFormatters.localizedTemplate(template, for: date, locale: locale),
                        expected,
                        "locale=\(locale.identifier) template=\(template) date=\(date)"
                    )
                }
            }
        }
    }

    /// 眉标整体文案（重构前是两个 inline formatter 拼接）也要逐字一致。
    func testEyebrowMatchesPreRefactorComposition() {
        for locale in locales {
            for date in dates {
                let expected: String = {
                    let dayFormatter = DateFormatter()
                    dayFormatter.locale = locale
                    dayFormatter.setLocalizedDateFormatFromTemplate("MMMd")

                    let weekdayFormatter = DateFormatter()
                    weekdayFormatter.locale = locale
                    weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")

                    return "\(dayFormatter.string(from: date)) · \(weekdayFormatter.string(from: date))"
                }()
                XCTAssertEqual(
                    TodayHeaderDateText.eyebrow(for: date, locale: locale),
                    expected,
                    "locale=\(locale.identifier) date=\(date)"
                )
            }
        }
    }

    // MARK: - 缓存确实生效

    /// 光比对输出无法区分「缓存了」和「每次都新建但格式一样」——issue #55 就是栽在
    /// 这一点上，所以这里直接断言底层 `DateFormatter` 的构造次数不再增长。
    func testRepeatedCallsDoNotRebuildFormatters() {
        let locale = Locale(identifier: "zh_CN")
        let date = dates[0]

        // 先各触发一次，把这些 locale/模板的槽位填满。
        _ = CachedDateFormatters.mediumDateShortTime(for: date, locale: locale)
        _ = CachedDateFormatters.monthTitle(for: date, locale: locale)
        _ = CachedDateFormatters.dayNumber(for: date, locale: locale)
        _ = CachedDateFormatters.shortStandaloneWeekdays(locale: locale)
        _ = CachedDateFormatters.localizedTemplate("MMMd", for: date, locale: locale)
        _ = CachedDateFormatters.localizedTemplate("EEE", for: date, locale: locale)

        let warmCount = CachedDateFormatters.formatterConstructionCount

        for _ in 0..<50 {
            _ = CachedDateFormatters.mediumDateShortTime(for: date, locale: locale)
            _ = CachedDateFormatters.monthTitle(for: date, locale: locale)
            _ = CachedDateFormatters.dayNumber(for: date, locale: locale)
            _ = CachedDateFormatters.shortStandaloneWeekdays(locale: locale)
            _ = CachedDateFormatters.localizedTemplate("MMMd", for: date, locale: locale)
            _ = CachedDateFormatters.localizedTemplate("EEE", for: date, locale: locale)
        }

        XCTAssertEqual(
            CachedDateFormatters.formatterConstructionCount,
            warmCount,
            "预热之后不应再构造新的 DateFormatter"
        )
    }
}
