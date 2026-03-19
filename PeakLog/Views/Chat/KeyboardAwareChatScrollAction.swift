import CoreGraphics

struct KeyboardAwareChatScrollAction {
    func shouldScrollToLatestMessage(
        previousKeyboardHeight: CGFloat,
        currentKeyboardHeight: CGFloat
    ) -> Bool {
        currentKeyboardHeight > previousKeyboardHeight
    }
}
