import SwiftUI

/// 统一训练页钉顶的周历条。收起态为 7 日一行（左右滑动切周），
/// 展开态为 6×7 月网格（箭头/滑动切月）。圆点语义：实心 = 有完成
/// 记录；空心 = 今天或未来有计划安排（见 `CalendarDay.showsPlanIndicator`）。
struct WeekCalendarStrip: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var isExpanded = false
    @Environment(\.locale) private var locale

    private static let toggleSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var weekdays: [String] {
        CalendarDateText.weekdays(locale: locale)
    }

    var body: some View {
        VStack(spacing: 8) {
            if isExpanded {
                monthNavigation
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
        .padding(.top, 4)
        .clipped()
        .contentShape(Rectangle())
        .gesture(horizontalPagingGesture)
        .animation(Self.toggleSpring, value: isExpanded)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 0.5)
        }
        .background(Color.appBackground)
    }

    // MARK: - Paging (swipe left/right)

    /// 横向滑动翻页：收起态切周，展开态切月。竖向为主的拖动直接放行，
    /// 避免与页面滚动/日期点按抢手势。
    private var horizontalPagingGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                let horizontal = value.translation.width
                guard abs(horizontal) > 40, abs(horizontal) > abs(value.translation.height) else { return }
                if isExpanded {
                    withAnimation(Self.toggleSpring) {
                        if horizontal > 0 {
                            viewModel.goToPreviousMonth()
                        } else {
                            viewModel.goToNextMonth()
                        }
                    }
                    Task { await viewModel.loadCalendar() }
                } else {
                    Task {
                        if horizontal > 0 {
                            await viewModel.goToPreviousWeekAndRefresh()
                        } else {
                            await viewModel.goToNextWeekAndRefresh()
                        }
                    }
                }
            }
    }

    // MARK: - Month Navigation (expanded only)

    private var monthNavigation: some View {
        HStack {
            Button {
                withAnimation(Self.toggleSpring) {
                    viewModel.goToPreviousMonth()
                }
                Task { await viewModel.loadCalendar() }
            } label: {
                Image(systemName: "chevron.left")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundColor(.textSecondary)
                    .frame(width: 32, height: 32)
            }

            Spacer()

            Text(CalendarDateText.monthTitle(for: viewModel.displayedMonth, locale: locale))
                .appFont(size: 15, weight: .bold)
                .foregroundColor(.textPrimary)

            Spacer()

            Button {
                withAnimation(Self.toggleSpring) {
                    viewModel.goToNextMonth()
                }
                Task { await viewModel.loadCalendar() }
            } label: {
                Image(systemName: "chevron.right")
                    .appFont(size: 14, weight: .semibold)
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
                    .appFont(size: 11, weight: .medium)
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
            withAnimation(Self.toggleSpring) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .appFont(size: 12, weight: .semibold)
                .foregroundColor(.textMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(isExpanded ? "training.calendar.collapse" : "training.calendar.expand"))
        .accessibilityIdentifier("training.calendar.expandToggle")
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
                    Text(CalendarDateText.dayNumber(for: day.date, locale: locale))
                        .appFont(size: 14, weight: day.isToday || day.isSelected ? .bold : .regular)
                        .foregroundColor(textColor)

                    if day.showsWorkoutIndicator {
                        Circle()
                            .fill(day.isSelected ? Color.white : Color.accentPrimary)
                            .frame(width: 4, height: 4)
                    } else if day.showsPlanIndicator {
                        Circle()
                            .strokeBorder(
                                day.isSelected ? Color.white : Color.accentPrimary,
                                lineWidth: 1
                            )
                            .frame(width: 5, height: 5)
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
}

// MARK: - Cached Formatters

@MainActor
enum CalendarDateText {
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
    WeekCalendarStrip(viewModel: HistoryViewModel())
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
}
