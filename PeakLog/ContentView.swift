import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            guard newPhase == .active else { return }
            localizationManager.refreshFromSystem()
        }
    }

    // Tab switches are driven by withAnimation in HomeDockBar, so the screens
    // crossfade in the ZStack instead of hard-swapping while the dock animates.
    @ViewBuilder
    private var currentScreen: some View {
        switch selectedTab {
        case .calendar:
            HistoryScreen()
                .transition(pageTransition)
        case .plan:
            TodayWorkoutScreen(viewModel: todayViewModel)
                .transition(pageTransition)
        case .settings:
            ProfileScreen()
                .transition(pageTransition)
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
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
