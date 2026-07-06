import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject private var localizationManager: LocalizationManager

    @State private var selectedTab: HomeTab = .plan
    @StateObject private var todayViewModel = TodayWorkoutViewModel()

    var body: some View {
        ZStack {
            currentScreen
        }
        .safeAreaInset(edge: .bottom) {
            HomeDockBar(selectedTab: $selectedTab, planAction: planDockAction)
                .padding(.bottom, 8)
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
                .transition(.opacity)
        case .plan:
            TodayWorkoutScreen(viewModel: todayViewModel)
                .transition(.opacity)
        case .settings:
            ProfileScreen()
                .transition(.opacity)
        }
    }

    private var planDockAction: DockPlanAction? {
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
