import Foundation

enum LocalizedPlanText {
    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

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

    static func historyStrengthSectionSubtitle(exerciseCount: Int, setCount: Int, locale: Locale) -> String {
        formatted("history.completed.strength.subtitle", locale: locale, Int64(exerciseCount), Int64(setCount))
    }

    static func historyCardioSectionSubtitle(recordCount: Int, locale: Locale) -> String {
        formatted("history.completed.cardio.subtitle", locale: locale, Int64(recordCount))
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

    static func completedStrengthLine(_ count: Int, locale: Locale) -> String {
        formatted("history.completed.line.strength", locale: locale, Int64(count))
    }

    static func completedCardioLine(_ count: Int, locale: Locale) -> String {
        formatted("history.completed.line.cardio", locale: locale, Int64(count))
    }

    static func completedDurationLine(_ minutes: Int, locale: Locale) -> String {
        formatted("history.completed.line.duration", locale: locale, Int64(minutes))
    }

    static func completedDistanceLine(_ distance: String, locale: Locale) -> String {
        formatted("history.completed.line.distance", locale: locale, distance)
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

    static func weekdayLabel(dayIndex: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? formatter.shortWeekdaySymbols ?? []
        guard symbols.count == 7 else {
            return localized("plan.weekday.unknown")
        }

        let mondayFirst = Array(symbols[1...6]) + [symbols[0]]
        guard (1...7).contains(dayIndex) else {
            return localized("plan.weekday.unknown")
        }
        return mondayFirst[dayIndex - 1]
    }
}
