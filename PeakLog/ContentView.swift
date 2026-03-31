import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var authState: AuthStateManager
    @EnvironmentObject private var localizationManager: LocalizationManager

    @State private var showHistory = false
    @State private var showProfile = false

    var body: some View {
        ZStack {
            TodayWorkoutScreen(
                onShowHistory: {
                    withAnimation(.easeInOut(duration: 0.3)) { showHistory = true }
                },
                onShowProfile: {
                    withAnimation(.easeInOut(duration: 0.3)) { showProfile = true }
                }
            )

            if showHistory {
                HistoryScreen(onBack: {
                    withAnimation(.easeInOut(duration: 0.3)) { showHistory = false }
                })
                .transition(.move(edge: .leading))
                .zIndex(1)
            }

            if showProfile {
                ProfileScreen(
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.3)) { showProfile = false }
                    },
                    onSignOut: {
                        Task {
                            try? await authState.signOut()
                        }
                    }
                )
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }
        }
        .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
        .task(id: authState.currentUserId) {
            guard authState.currentUserId != nil else { return }
            await localizationManager.syncRemotePreferenceIfNeeded(profileService: SupabaseProfileService())
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, authState.currentUserId != nil else { return }
            localizationManager.refreshFromSystem()
            Task {
                await localizationManager.syncRemotePreferenceIfNeeded(profileService: SupabaseProfileService())
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(AuthStateManager())
}
