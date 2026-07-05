import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject private var localizationManager: LocalizationManager

    @State private var selectedTab: HomeTab = .plan

    var body: some View {
        ZStack {
            currentScreen
        }
        .safeAreaInset(edge: .bottom) {
            HomeDockBar(selectedTab: $selectedTab)
                .padding(.bottom, 8)
        }
        .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            localizationManager.refreshFromSystem()
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch selectedTab {
        case .calendar:
            HistoryScreen(onBack: { selectedTab = .plan })
        case .plan:
            TodayWorkoutScreen()
        case .settings:
            ProfileScreen(onBack: { selectedTab = .plan })
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
}
