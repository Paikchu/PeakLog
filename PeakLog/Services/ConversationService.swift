import Foundation

protocol ConversationServiceProtocol {
    func fetchOrCreateDefaultConversationId() async throws -> String
}

final class LocalConversationService: ConversationServiceProtocol {
    private let database: LocalAppDatabase

    init(database: LocalAppDatabase) {
        self.database = database
    }

    func fetchOrCreateDefaultConversationId() async throws -> String {
        try await database.fetchOrCreateDefaultConversationId()
    }
}

final class MockConversationService: ConversationServiceProtocol {
    private let local = LocalConversationService(database: .shared)

    func fetchOrCreateDefaultConversationId() async throws -> String {
        try await local.fetchOrCreateDefaultConversationId()
    }
}
