import Foundation

@main
struct ConversationLoadCoordinatorTestRunner {
    static func main() {
        beginLoadingClearsExistingConversationAndError()
        ignoresStaleConversationResultsFromPreviousUser()
        print("conversation_load_coordinator_test passed")
    }

    private static func beginLoadingClearsExistingConversationAndError() {
        var coordinator = ConversationLoadCoordinator(
            activeUserId: "old-user",
            defaultConversationId: "old-conversation",
            errorMessage: "stale error"
        )

        coordinator.beginLoading(for: "new-user")

        precondition(coordinator.activeUserId == "new-user", "Expected active user to switch to new-user")
        precondition(coordinator.defaultConversationId == nil, "Expected conversation to clear while loading")
        precondition(coordinator.errorMessage == nil, "Expected load error to clear while loading")
    }

    private static func ignoresStaleConversationResultsFromPreviousUser() {
        var coordinator = ConversationLoadCoordinator()

        coordinator.beginLoading(for: "user-a")
        coordinator.applyLoadedConversation(id: "conversation-a", errorMessage: nil as String?, for: "user-a")

        coordinator.beginLoading(for: "user-b")
        coordinator.applyLoadedConversation(id: "stale-conversation-a", errorMessage: "old error", for: "user-a")

        precondition(coordinator.defaultConversationId == nil, "Expected stale load result to be ignored")
        precondition(coordinator.errorMessage == nil, "Expected stale error to be ignored")

        coordinator.applyLoadedConversation(id: "conversation-b", errorMessage: nil as String?, for: "user-b")

        precondition(coordinator.defaultConversationId == "conversation-b", "Expected active user's conversation to be applied")
        precondition(coordinator.errorMessage == nil, "Expected no error after applying active user's conversation")
    }
}
