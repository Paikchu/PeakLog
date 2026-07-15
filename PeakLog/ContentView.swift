import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject private var localizationManager: LocalizationManager

    @State private var selectedTab: HomeTab = .plan
    @StateObject private var todayViewModel = TodayWorkoutViewModel()

    // 专注训练时 dock 让位给底部确认栏。
    private var isTrainingFocusVisible: Bool {
        selectedTab == .plan && todayViewModel.isTrainingFocusActive && todayViewModel.activeLiveWorkout != nil
    }

    var body: some View {
        ZStack {
            currentScreen
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let actionState = trainingActionState {
                    TrainingActionLayer(state: actionState, action: handleTrainingAction)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if isTrainingFocusVisible {
                    TrainingFocusBar(viewModel: todayViewModel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HomeDockBar(selectedTab: $selectedTab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 8)
            .animation(HomeDockBar.dockSpring, value: isTrainingFocusVisible)
            .animation(HomeDockBar.dockSpring, value: trainingActionState)
        }
        .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
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

    // Screens hard-swap on tab change; only the dock animates its own
    // selection capsule (scoped inside HomeDockBar).
    @ViewBuilder
    private var currentScreen: some View {
        switch selectedTab {
        case .calendar:
            HistoryScreen()
        case .plan:
            TodayWorkoutScreen(viewModel: todayViewModel)
        case .settings:
            ProfileScreen()
        }
    }

    // Dock 上方的训练动作层状态：有最小化的活跃 session 时全局显示「训练进行中」；
    // 否则仅在计划页、今日有可训练计划时显示「开始训练」。
    private var trainingActionState: TrainingActionLayer.State? {
        guard !isTrainingFocusVisible else { return nil }
        if let session = todayViewModel.activeLiveWorkout {
            return .resume(completed: session.completedSetsCount, total: session.totalSetsCount)
        }
        guard selectedTab == .plan,
              let plan = todayViewModel.todayPlan,
              plan.totalSetsCount > 0 else { return nil }
        return .start
    }

    private func handleTrainingAction() {
        withAnimation(HomeDockBar.dockSpring) {
            if todayViewModel.activeLiveWorkout != nil {
                // 从任意 tab 一键回到训练：先切回计划页再恢复专注模式。
                selectedTab = .plan
                todayViewModel.resumeTrainingFocus()
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
