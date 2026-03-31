import SwiftUI
import Combine
import Supabase

@main
struct PeakLogApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var authState = AuthStateManager()
    @StateObject private var localizationManager = LocalizationManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.appBackground.ignoresSafeArea())
                } else if authState.isAuthenticated {
                    ContentView()
                } else {
                    AuthView()
                }
            }
            .environmentObject(themeManager)
            .environmentObject(authState)
            .environmentObject(localizationManager)
            .environment(\.locale, localizationManager.locale)
            .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                guard newPhase == .active else { return }
                localizationManager.refreshFromSystem()
            }
        }
    }
}

// MARK: - Auth State Manager

@MainActor
final class AuthStateManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var currentUserId: String?

    private let supabase = SupabaseManager.shared.client

    init() {
        Task { await observeAuthChanges() }
    }

    private func observeAuthChanges() async {
        for await (event, session) in await supabase.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .tokenRefreshed:
                guard let session, !session.isExpired else {
                    isAuthenticated = false
                    currentUserId = nil
                    isLoading = false
                    continue
                }
                isAuthenticated = true
                currentUserId = session.user.id.uuidString
                isLoading = false
            case .signedOut:
                isAuthenticated = false
                currentUserId = nil
                isLoading = false
            default:
                isLoading = false
                break
            }
        }
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
    }
}
