import SwiftUI

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var authState: AuthStateManager

    @State private var showHistory = false
    @State private var showProfile = false

    var body: some View {
        ZStack {
            if let conversationId = authState.defaultConversationId {
                ChatScreen(
                    conversationId: conversationId,
                    onShowHistory: {
                        withAnimation(.easeInOut(duration: 0.3)) { showHistory = true }
                    },
                    onShowProfile: {
                        withAnimation(.easeInOut(duration: 0.3)) { showProfile = true }
                    }
                )
            } else {
                // Waiting for the default conversation to load
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBackground.ignoresSafeArea())
            }

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
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(AuthStateManager())
}
