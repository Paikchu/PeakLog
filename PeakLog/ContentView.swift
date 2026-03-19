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

                Text("AI Gym Logger")
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

                Text("Conversation not ready yet")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.textPrimary)

                Text(errorMessage ?? "You can still use the app while we recover your chat session.")
                    .font(.subheadline)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button(action: onRetry) {
                    Text("Retry Conversation Load")
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
