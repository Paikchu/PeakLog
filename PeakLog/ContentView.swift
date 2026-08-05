import SwiftUI

/// App 根容器。日历/计划/我的三个 Tab 融合为单一 `TrainingScreen`
/// 后不再有底部 dock：训练动作层（开始训练 / 训练进行中）与专注
/// 确认栏作为底部浮层直接挂在唯一主页面上。
struct ContentView: View {
    private static let bottomBarSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var localizationManager: LocalizationManager

    @StateObject private var todayViewModel = TodayWorkoutViewModel()
    @StateObject private var historyViewModel = HistoryViewModel()

    // 专注训练时训练动作层让位给底部确认栏。
    private var isTrainingFocusVisible: Bool {
        todayViewModel.isTrainingFocusActive && todayViewModel.activeLiveWorkout != nil
    }

    var body: some View {
        TrainingScreen(
            todayViewModel: todayViewModel,
            historyViewModel: historyViewModel
        )
        .safeAreaInset(edge: .bottom) {
            if isTrainingFocusVisible {
                TrainingFocusBar(viewModel: todayViewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let state = trainingActionState {
                TrainingActionLayer(state: state, action: handleTrainingAction)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Self.bottomBarSpring, value: isTrainingFocusVisible)
        .animation(Self.bottomBarSpring, value: trainingActionState)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                localizationManager.refreshFromSystem()
            case .inactive, .background:
                // 训练集勾选去抖窗口内 App 若被系统挂起/杀掉，待写入的最新状态会丢失
                // （见 #18）；失活/进入后台时立即把它冲刷落盘。
                todayViewModel.flushPendingLiveWorkoutPersistence()
            @unknown default:
                break
            }
        }
    }

    // 底部训练动作层状态：有最小化的活跃 session 时，无论正在看哪一天都
    // 显示「训练进行中」；正在看今天且还有未完成的力量组时显示「开始训练」；
    // 今日力量组全部完成且本会话留有训练小结时显示「查看小结」入口——
    // 已经 ✓ 完成的一天不再出现无处可去的主 CTA。
    private var trainingActionState: TrainingActionLayer.State? {
        TrainingActionLayer.State.resolve(
            isTrainingFocusVisible: isTrainingFocusVisible,
            activeSessionProgress: todayViewModel.activeLiveWorkout.map {
                (completed: $0.completedSetsCount, total: $0.totalSetsCount)
            },
            isSelectedDateToday: historyViewModel.isSelectedDateToday,
            hasPlanSets: (todayViewModel.todayPlan?.totalSetsCount ?? 0) > 0,
            hasPendingStrengthSets: todayViewModel.todayPlan?.hasPendingStrengthSets == true,
            hasSessionSummary: todayViewModel.sessionSummary != nil
        )
    }

    private func handleTrainingAction() {
        withAnimation(Self.bottomBarSpring) {
            if todayViewModel.activeLiveWorkout != nil {
                // 从任意日期一键回到训练：先跳回今天再恢复专注模式。
                if !historyViewModel.isSelectedDateToday {
                    Task { await historyViewModel.selectTodayAndRefresh() }
                }
                todayViewModel.resumeTrainingFocus()
            } else if trainingActionState == .summary {
                todayViewModel.isPresentingSessionSummary = true
            } else {
                todayViewModel.startPlanLiveWorkout()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
}
