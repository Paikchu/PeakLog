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

    func fetchOrCreateDefaultConversationId() async throws -> String {
        if let existingId = try await fetchLatestConversationId() {
            return existingId
        }

        let session = try await supabase.auth.session

        let inserted: ConversationRow = try await supabase
            .from("conversations")
            .insert(
                ConversationInsertPayload(
                    userId: session.user.id.uuidString,
                    title: "Today Workout",
                    conversationType: "default"
                )
            )
            .select("id")
            .single()
            .execute()
            .value

        return inserted.id
    }

    private func fetchLatestConversationId() async throws -> String? {
        let rows: [ConversationRow] = try await supabase
            .from("conversations")
            .select("id")
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
