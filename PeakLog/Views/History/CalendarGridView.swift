import SwiftUI

struct CalendarGridView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var isExpanded = false
    @Environment(\.locale) private var locale

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var weekdays: [String] {
        CalendarDateText.weekdays(locale: locale)
    }

    private var displayedMonthTitle: String {
        CalendarDateText.monthTitle(for: viewModel.displayedMonth, locale: locale)
    }

    var body: some View {
        VStack(spacing: 10) {
            monthNavigation
            weekdayHeader

            if isExpanded {
                dayGrid
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                weekRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            expandToggle
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .clipped()
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isExpanded)
    }

    // MARK: - Month Navigation
    private var monthNavigation: some View {
        HStack {
            Button {
                if isExpanded {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        viewModel.goToPreviousMonth()
                    }
                    Task { await viewModel.loadCalendar() }
                } else {
                    Task { await viewModel.goToPreviousWeekAndRefresh() }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 32, height: 32)
            }

            Spacer()

            Text(displayedMonthTitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.textPrimary)

            Spacer()

            Button {
                if isExpanded {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        viewModel.goToNextMonth()
                    }
                    Task { await viewModel.loadCalendar() }
                } else {
                    Task { await viewModel.goToNextWeekAndRefresh() }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textSecondary)
                    .frame(width: 32, height: 32)
            }
        }
    }

    // MARK: - Weekday Header
    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdays, id: \.self) { day in
                Text(day)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.textMuted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Week Row (collapsed)
    private var weekRow: some View {
        HStack(spacing: 0) {
            ForEach(viewModel.currentWeekDays()) { day in
                DayCell(day: day) {
                    Task { await viewModel.selectDateAndRefresh(day.date) }
                }
            }
        }
    }

    // MARK: - Day Grid (expanded)
    private var dayGrid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(viewModel.calendarDays()) { day in
                DayCell(day: day) {
                    Task { await viewModel.selectDateAndRefresh(day.date) }
                }
            }
        }
    }

    // MARK: - Expand Toggle
    private var expandToggle: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.textMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
        }
    }

}

// MARK: - Day Cell

private struct DayCell: View {
    let day: CalendarDay
    let onTap: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button {
            if day.isInteractable { onTap() }
        } label: {
            ZStack {
                if day.showsSelectionHighlight {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentPrimary)
                        .frame(width: 36, height: 36)
                } else if day.showsTodayOutline {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentPrimary, lineWidth: 1.5)
                        .frame(width: 36, height: 36)
                }

                VStack(spacing: 3) {
                    Text(dayNumber(day.date))
                        .font(.system(size: 14, weight: day.isToday || day.isSelected ? .bold : .regular))
                        .foregroundColor(textColor)

                    if day.showsWorkoutIndicator {
                        Circle()
                            .fill(day.isSelected ? Color.white : Color.accentPrimary)
                            .frame(width: 4, height: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
                .frame(height: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var textColor: Color {
        switch day.textColorRole {
        case .selected:
            return .white
        case .primary:
            return .textPrimary
        case .muted:
            return .textDarkMuted
        }
    }

    private func dayNumber(_ date: Date) -> String {
        CalendarDateText.dayNumber(for: date, locale: locale)
    }
}

@MainActor
private enum CalendarDateText {
    private static var weekdayFormatters: [String: DateFormatter] = [:]
    private static var monthTitleFormatters: [String: DateFormatter] = [:]
    private static var dayNumberFormatters: [String: DateFormatter] = [:]

    static func weekdays(locale: Locale) -> [String] {
        let formatter = weekdayFormatter(locale: locale)
        return formatter.shortStandaloneWeekdaySymbols
    }

    static func monthTitle(for date: Date, locale: Locale) -> String {
        monthTitleFormatter(locale: locale).string(from: date)
    }

    static func dayNumber(for date: Date, locale: Locale) -> String {
        dayNumberFormatter(locale: locale).string(from: date)
    }

    private static func weekdayFormatter(locale: Locale) -> DateFormatter {
        cachedFormatter(in: &weekdayFormatters, locale: locale)
    }

    private static func monthTitleFormatter(locale: Locale) -> DateFormatter {
        cachedFormatter(in: &monthTitleFormatters, locale: locale) {
            $0.dateFormat = "MMMM yyyy"
        }
    }

    private static func dayNumberFormatter(locale: Locale) -> DateFormatter {
        cachedFormatter(in: &dayNumberFormatters, locale: locale) {
            $0.dateFormat = "d"
        }
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

        let formatter = DateFormatter()
        formatter.locale = locale
        configure(formatter)
        cache[key] = formatter
        return formatter
    }
}

#Preview {
    CalendarGridView(viewModel: HistoryViewModel())
        .padding()
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
}
