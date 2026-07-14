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
            Group {
                if isTrainingFocusVisible {
                    TrainingFocusBar(viewModel: todayViewModel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HomeDockBar(selectedTab: $selectedTab, planAction: planDockAction)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 8)
            .animation(HomeDockBar.dockSpring, value: isTrainingFocusVisible)
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

    private var planDockAction: DockPlanAction? {
        // 有最小化的活跃 session 时，槽位变成「继续训练」。
        if todayViewModel.activeLiveWorkout != nil {
            return DockPlanAction(
                title: String(localized: "training_session.resume"),
                isEnabled: true,
                action: { todayViewModel.resumeTrainingFocus() }
            )
        }

        guard let plan = todayViewModel.todayPlan, plan.totalSetsCount > 0 else { return nil }
        return DockPlanAction(
            title: String(localized: "today.start_training"),
            isEnabled: todayViewModel.activeLiveWorkout == nil,
            action: { todayViewModel.startPlanLiveWorkout() }
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
}
