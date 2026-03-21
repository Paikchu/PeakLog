import Foundation

@main
struct ChatScrollKeyboardDismissBehaviorTestRunner {
    static func main() {
        defaultBehaviorDismissesKeyboardOnScroll()
        print("chat_scroll_keyboard_dismiss_behavior_test passed")
    }

    private static func defaultBehaviorDismissesKeyboardOnScroll() {
        let behavior = ChatScrollKeyboardDismissBehavior()

        precondition(
            behavior.dismissesOnScroll,
            "Expected chat scroll keyboard dismiss behavior to dismiss keyboard during scroll interactions"
        )
    }
}
