import SwiftUI
import Combine
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
    @Published var conversationLoadError: String?

    private let supabase = SupabaseManager.shared.client
    private var conversationLoadCoordinator = ConversationLoadCoordinator()

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
                    applyConversationStateReset()
                    isLoading = false
                    continue
                }
                isAuthenticated = true
                currentUserId = session.user.id.uuidString
                isLoading = false
                beginConversationLoad(for: session.user.id.uuidString)
                Task {
                    await loadDefaultConversation(userId: session.user.id.uuidString)
                }
            case .signedOut:
                isAuthenticated = false
                currentUserId = nil
                applyConversationStateReset()
                isLoading = false
            default:
                isLoading = false
                break
            }
        }
    }

    private func loadDefaultConversation(userId: String) async {
        do {
            if let conversationId = try await fetchDefaultConversationId(
                userId: userId
            ) {
                applyLoadedConversation(id: conversationId, errorMessage: nil, for: userId)
                return
            }

            if let conversationId = try await createDefaultConversation(
                userId: userId
            ) {
                applyLoadedConversation(id: conversationId, errorMessage: nil, for: userId)
                return
            }

            applyLoadedConversation(
                id: nil,
                errorMessage: "No default conversation was available.",
                for: userId
            )
        } catch {
            applyLoadedConversation(
                id: nil,
                errorMessage: error.localizedDescription,
                for: userId
            )
            print("Failed to load default conversation: \(error)")
        }
    }

    func retryDefaultConversationLoad() async {
        guard let userId = currentUserId else { return }
        do {
            _ = try await supabase.auth.session
            beginConversationLoad(for: userId)
            await loadDefaultConversation(userId: userId)
        } catch {
            applyLoadedConversation(
                id: nil,
                errorMessage: error.localizedDescription,
                for: userId
            )
        }
    }

    private func fetchDefaultConversationId(
        userId: String
    ) async throws -> String? {
        let rows: [ConversationRow] = try await supabase
            .from("conversations")
            .select("id")
            .eq("user_id", value: userId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
            .limit(1)
            .execute()
            .value
        return rows.first?.id
    }

    private func createDefaultConversation(
        userId: String
    ) async throws -> String? {
        struct NewConversationRow: Decodable {
            let id: String
        }

        let rows: [NewConversationRow] = try await supabase
            .from("conversations")
            .insert([
                "user_id": userId,
                "title": "My Workout Log",
                "conversation_type": "default"
            ])
            .select("id")
            .execute()
            .value

        return rows.first?.id
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
    }

    private func beginConversationLoad(for userId: String) {
        conversationLoadCoordinator.beginLoading(for: userId)
        syncConversationState()
    }

    private func applyLoadedConversation(id conversationId: String?, errorMessage: String?, for userId: String) {
        conversationLoadCoordinator.applyLoadedConversation(
            id: conversationId,
            errorMessage: errorMessage,
            for: userId
        )
        syncConversationState()
    }

    private func applyConversationStateReset() {
        conversationLoadCoordinator.reset()
        syncConversationState()
    }

    private func syncConversationState() {
        defaultConversationId = conversationLoadCoordinator.defaultConversationId
        conversationLoadError = conversationLoadCoordinator.errorMessage
    }
}

// Minimal Codable row for conversation lookup
private struct ConversationRow: Decodable {
    let id: String
}
