import Foundation

enum LocalizedPlanText {
    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    /// 带计数的文案一律走这里。`locale` 不是可选装饰：字符串目录里的复数变体
    /// （`%#@count@`）只有在传入 locale 时才会展开，且展开时按**这个** locale 的
    /// 复数规则选 one/other——必须是 App 语言（`LocalizationManager.locale`，
    /// 由 `\.locale` 环境值下发），而不是设备的 `Locale.current`，否则系统语言
    /// 与 App 语言不一致时会选错分支（例如中文设备上英文界面显示 "1 sets"）。
    static func formatted(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: locale, arguments: arguments)
    }

    static func weekOf(_ weekStartDate: String, locale: Locale) -> String {
        formatted("plan.week_of", locale: locale, weekStartDate)
    }

    static func setsCompleted(completed: Int, total: Int, locale: Locale) -> String {
        formatted("plan.sets_completed", locale: locale, Int64(completed), Int64(total))
    }

    static func weeklyPlanSummary(trainingDays: Int, completedSets: Int, totalSets: Int, locale: Locale) -> String {
        formatted(
            "plan.weekly_summary",
            locale: locale,
            Int64(trainingDays),
            Int64(completedSets),
            Int64(totalSets)
        )
    }

    static func todayRunningSummary(distance: String, durationMinutes: Int, count: Int, locale: Locale) -> String {
        formatted("today.running.summary", locale: locale, distance, Int64(durationMinutes), Int64(count))
    }

    static func todayRunningRecordsSummary(distance: String, durationMinutes: Int, count: Int, locale: Locale) -> String {
        formatted("today.running.records_summary", locale: locale, distance, Int64(durationMinutes), Int64(count))
    }

    static func completedStrengthValue(_ count: Int, locale: Locale) -> String {
        formatted("history.completed.summary.strength_value", locale: locale, Int64(count))
    }

    static func completedSetValue(_ count: Int, locale: Locale) -> String {
        formatted("history.completed.summary.sets_value", locale: locale, Int64(count))
    }

    static func completedCardioValue(_ count: Int, locale: Locale) -> String {
        formatted("history.completed.summary.cardio_value", locale: locale, Int64(count))
    }

    static func completedStrengthBadge(_ setCount: Int, locale: Locale) -> String {
        formatted("history.completed.badge.completed_sets", locale: locale, Int64(setCount))
    }

    static func historyMetricDistance(_ distance: String, locale: Locale) -> String {
        formatted("history.completed.metric.distance_value", locale: locale, distance)
    }

    static func historyMetricDuration(_ minutes: Int, locale: Locale) -> String {
        formatted("history.completed.metric.duration_value", locale: locale, Int64(minutes))
    }

    static func planStatusKey(for status: String) -> String {
        switch status {
        case "planned":
            return "plan.status.planned"
        case "in_progress":
            return "plan.status.in_progress"
        case "completed":
            return "plan.status.completed"
        case "skipped":
            return "plan.status.skipped"
        case "rest":
            return "plan.status.rest"
        default:
            return "plan.status.unexpected"
        }
    }

    static func planStatusLabel(for status: String) -> String {
        localized(planStatusKey(for: status))
    }
}
