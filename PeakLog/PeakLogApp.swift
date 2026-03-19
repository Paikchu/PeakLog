import SwiftUI
import Supabase

@main
struct PeakLogApp: App {
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var authState = AuthStateManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.appBackground.ignoresSafeArea())
                } else if authState.isAuthenticated {
                    ContentView()
                        .environmentObject(themeManager)
                        .environmentObject(authState)
                } else {
                    AuthView()
                        .environmentObject(themeManager)
                        .environmentObject(authState)
                }
            }
            .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
        }
    }
}

// MARK: - Auth State Manager

@MainActor
final class AuthStateManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var currentUserId: String?
    @Published var defaultConversationId: String?

    private let supabase = SupabaseManager.shared.client

    init() {
        Task { await observeAuthChanges() }
    }

    private func observeAuthChanges() async {
        // Check existing session first
        if let session = try? await supabase.auth.session {
            isAuthenticated = true
            currentUserId = session.user.id.uuidString
            await fetchDefaultConversation(userId: session.user.id.uuidString)
        }
        isLoading = false

        // Observe future changes
        for await (event, session) in await supabase.auth.authStateChanges {
            switch event {
            case .signedIn, .tokenRefreshed:
                isAuthenticated = true
                currentUserId = session?.user.id.uuidString
                if let uid = session?.user.id.uuidString {
                    await fetchDefaultConversation(userId: uid)
                }
            case .signedOut:
                isAuthenticated = false
                currentUserId = nil
                defaultConversationId = nil
            default:
                break
            }
        }
    }

    private func fetchDefaultConversation(userId: String) async {
        do {
            let rows: [ConversationRow] = try await supabase
                .from("conversations")
                .select("id")
                .eq("user_id", value: userId)
                .is("deleted_at", value: nil)
                .order("created_at", ascending: true)
                .limit(1)
                .execute()
                .value
            defaultConversationId = rows.first?.id
        } catch {
            print("Failed to fetch default conversation: \(error)")
        }
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
    }
}

// Minimal Codable row for conversation lookup
private struct ConversationRow: Decodable {
    let id: String
}
