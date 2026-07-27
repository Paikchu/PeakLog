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

/// 训练页头部副标题的取材分支。标题恒为选中日期后，副标题只在「没有它就没别处
/// 可看」时才出现，这里只决定取哪一类文案，具体本地化字符串由视图层组装（跑步
/// 汇总要 locale 和记录明细，不适合塞进纯函数）。
///
/// 抽成纯函数是为了可测：视图里的计算属性直接读 `@ObservedObject`，测不到分支。
enum TrainingHeaderSubtitle: Equatable {
    /// 头部只留日期，不显示副标题。
    case dateOnly
    case freeRecordDay
    case runningOnly
    case emptyDay
    case completedMuscles

    static func resolve(
        tense: DayTense,
        hasPlan: Bool,
        isLoading: Bool,
        hasRecord: Bool,
        hasRunningRecords: Bool,
        hasCompletedMuscles: Bool
    ) -> TrainingHeaderSubtitle {
        switch tense {
        case .today:
            // 有计划（或仍在加载）时细节由内容区承载，头部不重复。
            // 反之内容区的摘要区不渲染（见 TodaySummarySection.hasScrollContent），
            // 副标题是当天唯一的说明文案。
            guard !hasPlan, !isLoading else { return .dateOnly }
            if hasRecord { return .freeRecordDay }
            if hasRunningRecords { return .runningOnly }
            return .emptyDay
        case .past:
            return hasCompletedMuscles ? .completedMuscles : .dateOnly
        case .futureInPlanWeek, .futureBeyondPlan:
            return .dateOnly
        }
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
