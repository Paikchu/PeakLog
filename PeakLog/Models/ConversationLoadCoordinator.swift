import Foundation

struct ConversationLoadCoordinator {
    private(set) var activeUserId: String?
    private(set) var defaultConversationId: String?
    private(set) var errorMessage: String?

    init(
        activeUserId: String? = nil,
        defaultConversationId: String? = nil,
        errorMessage: String? = nil
    ) {
        self.activeUserId = activeUserId
        self.defaultConversationId = defaultConversationId
        self.errorMessage = errorMessage
    }

    mutating func beginLoading(for userId: String) {
        activeUserId = userId
        defaultConversationId = nil
        errorMessage = nil
    }

    mutating func reset() {
        activeUserId = nil
        defaultConversationId = nil
        errorMessage = nil
    }

    mutating func applyLoadedConversation(
        id conversationId: String?,
        errorMessage: String?,
        for userId: String
    ) {
        guard activeUserId == userId else { return }
        defaultConversationId = conversationId
        self.errorMessage = errorMessage
    }
}
