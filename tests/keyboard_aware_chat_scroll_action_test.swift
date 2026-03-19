import CoreGraphics
import Foundation

@main
struct KeyboardAwareChatScrollActionTestRunner {
    static func main() {
        scrollsWhenKeyboardAppears()
        scrollsWhenKeyboardHeightIncreases()
        doesNotScrollWhenKeyboardHeightIsUnchanged()
        doesNotScrollWhenKeyboardDismisses()
        print("keyboard_aware_chat_scroll_action_test passed")
    }

    private static func scrollsWhenKeyboardAppears() {
        let action = KeyboardAwareChatScrollAction()

        let shouldScroll = action.shouldScrollToLatestMessage(
            previousKeyboardHeight: 0,
            currentKeyboardHeight: 316
        )

        precondition(shouldScroll, "Expected keyboard appearance to keep latest chat content visible")
    }

    private static func scrollsWhenKeyboardHeightIncreases() {
        let action = KeyboardAwareChatScrollAction()

        let shouldScroll = action.shouldScrollToLatestMessage(
            previousKeyboardHeight: 216,
            currentKeyboardHeight: 344
        )

        precondition(shouldScroll, "Expected taller keyboard frame to keep latest chat content visible")
    }

    private static func doesNotScrollWhenKeyboardHeightIsUnchanged() {
        let action = KeyboardAwareChatScrollAction()

        let shouldScroll = action.shouldScrollToLatestMessage(
            previousKeyboardHeight: 316,
            currentKeyboardHeight: 316
        )

        precondition(!shouldScroll, "Expected unchanged keyboard height not to trigger another forced scroll")
    }

    private static func doesNotScrollWhenKeyboardDismisses() {
        let action = KeyboardAwareChatScrollAction()

        let shouldScroll = action.shouldScrollToLatestMessage(
            previousKeyboardHeight: 316,
            currentKeyboardHeight: 0
        )

        precondition(!shouldScroll, "Expected keyboard dismissal not to behave like a new upward shift")
    }
}
