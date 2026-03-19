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
                .id(conversationId)
            } else {
                ConversationUnavailableView(
                    errorMessage: authState.conversationLoadError,
                    onRetry: {
                        Task { await authState.retryDefaultConversationLoad() }
                    },
                    onShowHistory: {
                        withAnimation(.easeInOut(duration: 0.3)) { showHistory = true }
                    },
                    onShowProfile: {
                        withAnimation(.easeInOut(duration: 0.3)) { showProfile = true }
                    }
                )
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

private struct ConversationUnavailableView: View {
    let errorMessage: String?
    let onRetry: () -> Void
    let onShowHistory: () -> Void
    let onShowProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onShowHistory) {
                    Image(systemName: "calendar")
                        .font(.system(size: 20))
                        .foregroundColor(.textPrimary)
                        .frame(width: 38, height: 38)
                }

                Spacer()

                Text("content.chat_title")
                    .font(.headerTitle)
                    .foregroundColor(.textPrimary)
                    .tracking(-0.4)

                Spacer()

                Button(action: onShowProfile) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.textPrimary)
                        .frame(width: 38, height: 38)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.textMuted)

                Text("content.conversation_unavailable.title")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.textPrimary)

                Text(errorMessage ?? String(localized: "content.conversation_unavailable.message"))
                    .font(.subheadline)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button(action: onRetry) {
                    Text("content.conversation_unavailable.retry")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.textPrimary)
                        .foregroundColor(Color.appBackground)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)
            }

            Spacer()
        }
        .background(Color.appBackground.ignoresSafeArea())
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(AuthStateManager())
}
