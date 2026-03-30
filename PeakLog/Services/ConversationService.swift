import Foundation
import Supabase

private struct ConversationRow: Decodable {
    let id: String
}

private struct ConversationInsertPayload: Encodable {
    let userId: String
    let title: String
    let conversationType: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case title
        case conversationType = "conversation_type"
    }
}

protocol ConversationServiceProtocol {
    func fetchOrCreateDefaultConversationId() async throws -> String
}

final class SupabaseConversationService: ConversationServiceProtocol {
    private let supabase = SupabaseManager.shared.client
    private static let defaultConversationType = "default"

    func fetchOrCreateDefaultConversationId() async throws -> String {
        let session = try await supabase.auth.session
        let userId = session.user.id.uuidString

        if let existingId = try await fetchLatestConversationId(
            userId: userId,
            conversationType: Self.defaultConversationType
        ) {
            return existingId
        }

        let inserted: ConversationRow = try await supabase
            .from("conversations")
            .insert(
                ConversationInsertPayload(
                    userId: userId,
                    title: "Today Workout",
                    conversationType: Self.defaultConversationType
                )
            )
            .select("id")
            .single()
            .execute()
            .value

        return inserted.id
    }

    private func fetchLatestConversationId(
        userId: String,
        conversationType: String
    ) async throws -> String? {
        let rows: [ConversationRow] = try await supabase
            .from("conversations")
            .select("id")
            .eq("user_id", value: userId)
            .eq("conversation_type", value: conversationType)
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first?.id
    }
}

final class MockConversationService: ConversationServiceProtocol {
    let conversationId: String

    init(conversationId: String = "mock-conversation") {
        self.conversationId = conversationId
    }

    func fetchOrCreateDefaultConversationId() async throws -> String {
        conversationId
    }
}
