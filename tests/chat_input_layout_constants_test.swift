import SwiftUI

@main
struct ChatInputLayoutConstantsTestRunner {
    static func main() {
        chatInputBarBottomPaddingProvidesExtraSpacing()
        chatInputBarSupportsSingleLineMinimumHeight()
        chatInputBarExpandsUpToFiveVisibleLines()
        print("chat_input_layout_constants_test passed")
    }

    private static func chatInputBarBottomPaddingProvidesExtraSpacing() {
        precondition(chatInputBarBottomPadding == 8, "Expected chat input bottom padding to be 8, got \(chatInputBarBottomPadding)")
        precondition(chatInputBarBottomPadding > 0, "Expected chat input bottom padding to leave visible spacing")
    }

    private static func chatInputBarSupportsSingleLineMinimumHeight() {
        precondition(
            chatInputBarMinimumVisibleLineCount == 1,
            "Expected chat input minimum visible line count to be 1, got \(chatInputBarMinimumVisibleLineCount)"
        )
    }

    private static func chatInputBarExpandsUpToFiveVisibleLines() {
        precondition(
            chatInputBarMaximumVisibleLineCount == 5,
            "Expected chat input maximum visible line count to be 5, got \(chatInputBarMaximumVisibleLineCount)"
        )
        precondition(
            chatInputBarMaximumVisibleLineCount > chatInputBarMinimumVisibleLineCount,
            "Expected chat input maximum visible lines to exceed its minimum visible lines"
        )
    }
}
