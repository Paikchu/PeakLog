import SwiftUI

struct HistoryScreen: View {
    @StateObject private var viewModel = HistoryViewModel()
    @State private var showsCalendarPopup = false
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header 随信息流上滑收起，回到顶部时复位，把滚动后的空间让给内容。
                dateHeader
                VStack(spacing: 16) {
                    sessionList
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .sheet(isPresented: $showsCalendarPopup) {
            CalendarPopupSheet(viewModel: viewModel)
        }
        .task {
            // The four loads write to disjoint published state (plan,
            // library, calendar activeDates, selected-day sessions) and none
            // reads another's result, so they run concurrently instead of
            // paying for four sequential round-trips. See
            // `loadInitialScreenData()` for how it keeps `errorMessage`
            // deterministic despite the four loaders racing.
            await viewModel.loadInitialScreenData()
        }
    }

    // MARK: - Date Header
    private var dateHeader: some View {
        RootPageHeader(
            title: selectedDateLabel,
            subtitle: viewModel.completedMuscleGroups.isEmpty ? nil : muscleFocusLine
        ) {
            Button {
                showsCalendarPopup = true
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentPrimary)
                    .frame(width: RootPageHeaderMetrics.trailingControlSize, height: RootPageHeaderMetrics.trailingControlSize)
                    .background(Color.appSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("history.calendar.open"))
            .accessibilityIdentifier("history.calendar.button")
        }
    }

    // “7月15日 · 周三”样式的日期标题，与计划页头部文字风格保持一致。
    private var selectedDateLabel: String {
        TodayHeaderDateText.eyebrow(for: viewModel.selectedDate, locale: locale)
    }

    private var muscleFocusLine: String {
        let names = viewModel.completedMuscleGroups
            .map(\.displayLabel)
            .joined(separator: " · ")
        return LocalizedPlanText.formatted("history.header.muscles", locale: locale, names)
    }

    @ViewBuilder
    private var sessionList: some View {
        if viewModel.isLoadingSessions {
            ProgressView()
                .padding(.top, 20)
        } else if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.chatBody)
                .foregroundColor(.textSecondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
        } else if !viewModel.hasCompletedRecords {
            let content = HistoryEmptyStateContent.resolve(
                selectedDate: viewModel.selectedDate,
                today: Date(),
                locale: locale
            )
            VStack(alignment: .leading, spacing: 12) {
                Text(content.title)
                    .font(.rootPageTitle)
                    .foregroundColor(.textPrimary)
                Text(content.subtitle)
                    .font(.system(size: 15))
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RootPageHeaderMetrics.horizontalPadding)
            .padding(.top, 28)
        } else {
            HistoryCompletedTrainingSection(
                summary: viewModel.completedDaySummary,
                strengthExercises: viewModel.completedStrengthExercises,
                cardioRecords: viewModel.completedCardioRecords
            )
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Calendar Popup

private struct CalendarPopupSheet: View {
    @ObservedObject var viewModel: HistoryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            CalendarGridView(viewModel: viewModel, alwaysExpanded: true)
                .padding(.horizontal, 16)
                .padding(.top, 20)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onChange(of: Calendar.current.startOfDay(for: viewModel.selectedDate)) { _, _ in
            dismiss()
        }
    }
}

#Preview {
    HistoryScreen()
        .preferredColorScheme(.dark)
}
