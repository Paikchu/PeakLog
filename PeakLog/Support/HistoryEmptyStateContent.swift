import Foundation

struct HistoryEmptyStateContent: Equatable {
    let isToday: Bool
    let title: String
    let subtitle: String

    static func resolve(selectedDate: Date, today: Date, locale: Locale) -> Self {
        let calendar = Calendar.current
        let isToday = calendar.isDate(selectedDate, inSameDayAs: today)
        return Self(
            isToday: isToday,
            title: String(localized: isToday ? "history.empty.today.title" : "history.empty.date.title", locale: locale),
            subtitle: String(localized: "history.empty.subtitle", locale: locale)
        )
    }
}
