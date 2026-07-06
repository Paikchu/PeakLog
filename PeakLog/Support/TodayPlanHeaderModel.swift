import Foundation

/// Plan 页头部标题解析：兜底标题（手动建计划的“自定义训练”）没有信息量，
/// 降级链为 计划标题 → focus → 默认“今日训练”。
struct TodayPlanHeader: Equatable {
    let title: String
    let subtitle: String?

    /// 手动建计划的兜底标题在两种语言下的取值；计划可能在任一语言下创建，都视为无信息量。
    static let genericTitles: Set<String> = ["Custom Workout", "自定义训练"]

    static func resolve(planTitle: String?, focus: String?, fallbackTitle: String) -> TodayPlanHeader {
        let title = planTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let focusText = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !title.isEmpty, !genericTitles.contains(title) {
            let subtitle = focusText.isEmpty || focusText == title ? nil : focusText
            return TodayPlanHeader(title: title, subtitle: subtitle)
        }
        if !focusText.isEmpty {
            return TodayPlanHeader(title: focusText, subtitle: nil)
        }
        return TodayPlanHeader(title: fallbackTitle, subtitle: nil)
    }
}

enum TodayHeaderDateText {
    /// “7月6日 · 周一” / “Jul 6 · Mon” 眉标文本，按 locale 取模板格式。
    static func eyebrow(for date: Date = Date(), locale: Locale) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.setLocalizedDateFormatFromTemplate("MMMd")

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = locale
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")

        return "\(dayFormatter.string(from: date)) · \(weekdayFormatter.string(from: date))"
    }
}
