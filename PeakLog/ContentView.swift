import SwiftUI

struct ContentView: View {
    private static let bottomBarSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)

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
        TabView(selection: $selectedTab) {
            Tab(value: HomeTab.calendar) {
                HistoryScreen()
                    .trainingActionInset(state: trainingActionState, action: handleTrainingAction)
            } label: {
                Label(HomeTab.calendar.title, systemImage: HomeTab.calendar.symbolName)
            }

            Tab(value: HomeTab.plan) {
                TodayWorkoutScreen(viewModel: todayViewModel)
                    .toolbarVisibility(isTrainingFocusVisible ? .hidden : .visible, for: .tabBar)
                    .trainingActionInset(state: trainingActionState, action: handleTrainingAction)
            } label: {
                Label(HomeTab.plan.title, systemImage: HomeTab.plan.symbolName)
            }

            Tab(value: HomeTab.settings) {
                ProfileScreen()
                    .trainingActionInset(state: trainingActionState, action: handleTrainingAction)
            } label: {
                Label(HomeTab.settings.title, systemImage: HomeTab.settings.symbolName)
            }
        }
        .modifier(TrainingActionAccessoryModifier(
            state: trainingActionState,
            action: handleTrainingAction
        ))
        .safeAreaInset(edge: .bottom) {
            if isTrainingFocusVisible {
                TrainingFocusBar(viewModel: todayViewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Self.bottomBarSpring, value: isTrainingFocusVisible)
        .animation(Self.bottomBarSpring, value: trainingActionState)
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

    // Tab Bar 上方的训练动作层状态：有最小化的活跃 session 时全局显示「训练进行中」；
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
        withAnimation(Self.bottomBarSpring) {
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

private struct TrainingActionInsetModifier: ViewModifier {
    let state: TrainingActionLayer.State?
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom) {
                if let state {
                    TrainingActionLayer(state: state, action: action)
                }
            }
        }
    }
}

private struct TrainingActionAccessoryModifier: ViewModifier {
    let state: TrainingActionLayer.State?
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: state != nil) {
                if let state {
                    TrainingActionLayer(state: state, action: action)
                }
            }
        } else {
            content
        }
    }
}

private extension View {
    func trainingActionInset(
        state: TrainingActionLayer.State?,
        action: @escaping () -> Void
    ) -> some View {
        modifier(TrainingActionInsetModifier(state: state, action: action))
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
}
