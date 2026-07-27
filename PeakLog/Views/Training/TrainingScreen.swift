import SwiftUI

/// 统一训练页：日历页与计划页融合后的唯一主页面。
/// 骨架恒定为「头部 + 钉顶周条 + 内容区」，选中日期的时态
/// （`DayTense`）决定内容区是只读记录、可交互计划还是只读预览；
/// 专注训练模式下头部与周条整体让位给 `TodayWorkoutScreen` 的专注头。
struct TrainingScreen: View {
    // 两个 ViewModel 都由 ContentView 持有：today 侧承载浮动训练动作层
    // 的状态，history 侧承载"是否在看今天"的判断。Phase B 开放未来编辑
    // 时再评估合并为单一 TrainingViewModel。
    @ObservedObject var todayViewModel: TodayWorkoutViewModel
    @ObservedObject var historyViewModel: HistoryViewModel

    @State private var isPresentingProfile = false
    @Environment(\.locale) private var locale

    private static let tenseTransition = Animation.easeInOut(duration: 0.2)

    private var isFocusMode: Bool {
        todayViewModel.isTrainingFocusActive && todayViewModel.activeLiveWorkout != nil
    }

    private var tense: DayTense {
        historyViewModel.selectedDayTense
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFocusMode {
                pageHeader
                    .transition(.opacity.combined(with: .move(edge: .top)))
                WeekCalendarStrip(viewModel: historyViewModel)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            content
        }
        .background(Color.appBackground.ignoresSafeArea())
        .animation(Self.tenseTransition, value: isFocusMode)
        .sheet(isPresented: $isPresentingProfile) {
            ProfileScreen()
                .presentationDragIndicator(.visible)
        }
        .task {
            await historyViewModel.loadInitialScreenData()
        }
    }

    // MARK: - Content Routing

    @ViewBuilder
    private var content: some View {
        // 专注模式只可能发生在今天：从其他日期一键恢复训练时，"跳回今天"
        // 是异步刷新，这里直接锚定今天的内容，避免过渡期间闪过旧日期内容。
        if isFocusMode {
            TodayWorkoutScreen(viewModel: todayViewModel)
        } else {
            switch tense {
            case .today:
                TodayWorkoutScreen(viewModel: todayViewModel)
            case .past:
                PastDayContent(viewModel: historyViewModel)
            case .futureInPlanWeek, .futureBeyondPlan:
                FutureDayContent(tense: tense, historyViewModel: historyViewModel)
                    // 未来日之间切换共用同一调用点，SwiftUI 会复用视图身份，
                    // isReordering/draftOrder 等编辑状态会跨日期泄漏（重排中
                    // 切日后提交会拿旧日期的动作 id 写新日期，PR #115 review）。
                    // 按"天"作为身份键，换天即重建整棵编辑状态。
                    .id(Calendar.current.startOfDay(for: historyViewModel.selectedDate))
            }
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        let header = resolvedHeader
        return RootPageHeader(title: header.title, subtitle: header.subtitle) {
            HStack(spacing: 8) {
                if tense == .today, isPlanComplete {
                    completedChip
                }
                if tense != .today {
                    backToTodayButton
                }
                profileButton
            }
        }
    }

    /// 头部标题恒为选中日期，不随计划标题变化——今天和其他日子一视同仁。
    /// 副标题只在「没有它就没别处可看」时出现：今天无计划时的状态兜底、
    /// 过去的已练肌群；有计划的今天和未来日都只留日期（细节由内容区承载）。
    private var resolvedHeader: TodayPlanHeader {
        TodayPlanHeader(title: dateTitle, subtitle: headerSubtitle)
    }

    /// 分支判断在 `TrainingHeaderSubtitle.resolve` 里（纯函数、有单测覆盖），
    /// 这里只负责把选中的分支翻译成本地化文案。
    private var headerSubtitle: String? {
        let source = TrainingHeaderSubtitle.resolve(
            tense: tense,
            hasPlan: todayViewModel.todayPlan != nil,
            isLoading: todayViewModel.isLoading,
            hasRecord: todayViewModel.todayRecord != nil,
            hasRunningRecords: !todayViewModel.runningRecords.isEmpty,
            hasCompletedMuscles: !historyViewModel.completedMuscleGroups.isEmpty
        )

        switch source {
        case .dateOnly:
            return nil
        case .freeRecordDay:
            return nil
        case .runningOnly:
            return runningOnlyLine
        case .emptyDay:
            return nil
        case .completedMuscles:
            return muscleFocusLine
        }
    }

    private var dateTitle: String {
        TodayHeaderDateText.eyebrow(for: historyViewModel.selectedDate, locale: locale)
    }

    private var muscleFocusLine: String {
        let names = historyViewModel.completedMuscleGroups
            .map(\.displayLabel)
            .joined(separator: " · ")
        return LocalizedPlanText.formatted("history.header.muscles", locale: locale, names)
    }

    private var runningOnlyLine: String {
        let totalDistance = todayViewModel.runningRecords.reduce(0.0) { $0 + ($1.distanceKm ?? 0) }
        let totalDuration = todayViewModel.runningRecords.reduce(0) { $0 + $1.durationMinutes }
        return LocalizedPlanText.todayRunningRecordsSummary(
            distance: totalDistance.cleanDistance,
            durationMinutes: totalDuration,
            count: todayViewModel.runningRecords.count,
            locale: locale
        )
    }

    // MARK: - Header Controls

    private var isPlanComplete: Bool {
        guard let plan = todayViewModel.todayPlan else { return false }
        return plan.totalProgressUnits > 0 && plan.completedProgressUnits >= plan.totalProgressUnits
    }

    private var completedChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .appFont(size: 9, weight: .bold)
            Text("today.header.completed")
                .appFont(size: 11, weight: .bold)
        }
        .foregroundColor(.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.green.opacity(0.14)))
        .transition(.scale.combined(with: .opacity))
    }

    private var backToTodayButton: some View {
        Button {
            Task { await historyViewModel.selectTodayAndRefresh() }
        } label: {
            Text("training.back_to_today")
                .appFont(size: 13, weight: .semibold)
                .foregroundColor(.accentPrimary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Color.appSurface))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("training.backToToday")
        .transition(.scale.combined(with: .opacity))
    }

    private var profileButton: some View {
        Button {
            isPresentingProfile = true
        } label: {
            Image(systemName: "person")
                .appFont(size: 20, weight: .medium)
                .foregroundColor(.accentPrimary)
                .frame(
                    width: RootPageHeaderMetrics.trailingControlSize,
                    height: RootPageHeaderMetrics.trailingControlSize
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("training.profile.open"))
        .accessibilityIdentifier("training.profile.button")
    }
}

private extension Double {
    var cleanDistance: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }
}

private struct TrainingScreenPreview: View {
    @MainActor
    var body: some View {
        TrainingScreen(
            todayViewModel: TodayWorkoutViewModel(),
            historyViewModel: HistoryViewModel()
        )
        .environmentObject(CloudSyncController())
        .environmentObject(ThemeManager())
        .environmentObject(LocalizationManager())
    }
}

#Preview {
    TrainingScreenPreview()
        .preferredColorScheme(.dark)
}
