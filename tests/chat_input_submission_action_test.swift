import Foundation

@main
struct ChatInputSubmissionActionTestRunner {
    static func main() {
        submitCallsSendWhenTextIsNotEmptyAndNotSending()
        submitDoesNotCallSendWhenTextIsEmpty()
        submitDoesNotCallSendWhenAlreadySending()
        print("chat_input_submission_action_test passed")
    }

    private static func submitCallsSendWhenTextIsNotEmptyAndNotSending() {
        var sendCount = 0
        let action = ChatInputSubmissionAction {
            sendCount += 1
        }

        let didSend = action.submit(text: "bench press", isSending: false)

        precondition(didSend, "Expected submit to report success for non-empty text")
        precondition(sendCount == 1, "Expected send handler to be called once")
    }

    private static func submitDoesNotCallSendWhenTextIsEmpty() {
        var sendCount = 0
        let action = ChatInputSubmissionAction {
            sendCount += 1
        }

        let didSend = action.submit(text: "   ", isSending: false)

        precondition(!didSend, "Expected submit to reject blank text")
        precondition(sendCount == 0, "Expected send handler not to be called for blank text")
    }

    private static func submitDoesNotCallSendWhenAlreadySending() {
        var sendCount = 0
        let action = ChatInputSubmissionAction {
            sendCount += 1
        }

        let didSend = action.submit(text: "squat", isSending: true)

        precondition(!didSend, "Expected submit to reject input while already sending")
        precondition(sendCount == 0, "Expected send handler not to be called while sending")
    }
}
