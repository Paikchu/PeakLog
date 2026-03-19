import Foundation

struct ChatInputSubmissionAction {
    private let sendHandler: () -> Void

    init(sendHandler: @escaping () -> Void) {
        self.sendHandler = sendHandler
    }

    func submit(text: String, isSending: Bool) -> Bool {
        guard !isSending else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        sendHandler()
        return true
    }
}
