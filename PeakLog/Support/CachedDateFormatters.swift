import Foundation

/// 视图层按 locale 复用的 `DateFormatter` 缓存。
///
/// 和 `WorkoutDateFormatter` 是同一条推理，只是缓存的键不同：真正贵的是
/// `DateFormatter` 的构造（locale/timezone/calendar 初始化），所以被缓存的必须是
/// `DateFormatter` 本身，而不是某个包装器——缓存包装器仍然会在每次格式化时新建
/// formatter，issue #55 已经证明那样拿不到收益。`WorkoutDateFormatter` 的格式
/// （"yyyy-MM-dd" + POSIX locale）是固定的，一个实例懒建一个 formatter 就够；
/// 这里的输出必须跟随调用方传入的 locale，所以按 locale 标识符分桶缓存。
///
/// 几种格式刻意分开缓存、不合并成一个 formatter：`mediumDateShortTime` 是
/// 「日期 + 时刻」、`monthTitle` 是「月 + 年」、`dayNumber` 是纯日号、
/// `localizedTemplate` 是按 locale 重排字段的模板格式，输出字符串各不相同，
/// 共用一个 formatter 会直接改掉各处的可见文案。
///
/// `@MainActor` 而不是 `CloudDate` 那种 `nonisolated(unsafe) private static let`：
/// 后者适用于「构造一次之后只读」的常量 formatter，而这里的缓存字典是可变状态，
/// 不满足那个前提，需要真正的隔离而不是隔离豁免。全部调用点都在 SwiftUI 视图或
/// `@MainActor` 的视图模型上，主线程隔离不构成额外约束。
@MainActor
enum CachedDateFormatters {
    /// 统计底层 `DateFormatter` 真正被构造了几次，让测试能断言缓存确实生效，
    /// 而不是只检查输出正确（`WorkoutDateFormatter.formatterConstructionCount`
    /// 出于 issue #55 的同一理由存在）。缓存未命中时才自增，代价可忽略。
    static private(set) var formatterConstructionCount = 0

    private static var mediumDateShortTimeFormatters: [String: DateFormatter] = [:]
    private static var monthTitleFormatters: [String: DateFormatter] = [:]
    private static var weekdaySymbolFormatters: [String: DateFormatter] = [:]
    private static var dayNumberFormatters: [String: DateFormatter] = [:]
    private static var templateFormatters: [String: DateFormatter] = [:]

    /// `dateStyle = .medium` + `timeStyle = .short`，训练/跑步记录卡的“创建于”文案。
    static func mediumDateShortTime(for date: Date, locale: Locale) -> String {
        cachedFormatter(in: &mediumDateShortTimeFormatters, locale: locale) {
            $0.dateStyle = .medium
            $0.timeStyle = .short
        }
        .string(from: date)
    }

    /// 日历月份标题（"MMMM yyyy"）。
    static func monthTitle(for date: Date, locale: Locale) -> String {
        cachedFormatter(in: &monthTitleFormatters, locale: locale) {
            $0.dateFormat = "MMMM yyyy"
        }
        .string(from: date)
    }

    /// 日历格子里的日号（"d"）。
    static func dayNumber(for date: Date, locale: Locale) -> String {
        cachedFormatter(in: &dayNumberFormatters, locale: locale) {
            $0.dateFormat = "d"
        }
        .string(from: date)
    }

    /// 周历表头的短星期符号。
    static func shortStandaloneWeekdays(locale: Locale) -> [String] {
        cachedFormatter(in: &weekdaySymbolFormatters, locale: locale).shortStandaloneWeekdaySymbols
    }

    /// `setLocalizedDateFormatFromTemplate`：模板固定，字段顺序和分隔符由 locale 决定。
    /// 缓存键必须带上模板本身，否则同一 locale 下不同模板会互相顶掉。
    static func localizedTemplate(_ template: String, for date: Date, locale: Locale) -> String {
        let key = "\(template)|\(locale.identifier)"
        if let formatter = templateFormatters[key] {
            return formatter.string(from: date)
        }

        formatterConstructionCount += 1
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        templateFormatters[key] = formatter
        return formatter.string(from: date)
    }

    private static func cachedFormatter(
        in cache: inout [String: DateFormatter],
        locale: Locale,
        configure: (DateFormatter) -> Void = { _ in }
    ) -> DateFormatter {
        let key = locale.identifier
        if let formatter = cache[key] {
            return formatter
        }

        formatterConstructionCount += 1
        let formatter = DateFormatter()
        formatter.locale = locale
        configure(formatter)
        cache[key] = formatter
        return formatter
    }
}
