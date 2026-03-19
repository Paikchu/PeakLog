import Foundation
import Combine

@main
struct ChatViewModelOptimisticSendTestRunner {
    static func main() async {
        await sentMessageAppearsImmediatelyBeforeNetworkReturns()
        await failedSendRestoresInputAndRemovesOptimisticMessages()
        print("chat_view_model_optimistic_send_test passed")
    }

    @MainActor
    private static func sentMessageAppearsImmediatelyBeforeNetworkReturns() async {
        let chatService = ControlledChatService()
        await chatService.setMessagesToFetch([
            ChatMessage(
                id: "server-user-1",
                sessionId: "conversation-1",
                role: .user,
                text: "Logged 5x5 squat",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            ChatMessage(
                id: "server-assistant-1",
                sessionId: "conversation-1",
                role: .assistant,
                text: "Saved it.",
                createdAt: Date(timeIntervalSince1970: 101),
                status: .completed
            )
        ])

        let viewModel = ChatViewModel(
            conversationId: "conversation-1",
            chatService: chatService,
            workoutService: TestWorkoutService()
        )
        viewModel.inputText = "Logged 5x5 squat"

        let sendTask = Task {
            await viewModel.sendMessage()
        }

        await chatService.waitForSendToStart()
        await Task.yield()

        let optimisticMessages = viewModel.messageGroups.flatMap(\.messages)
        precondition(optimisticMessages.count == 2, "Expected optimistic user and assistant messages before send finishes")
        precondition(optimisticMessages.contains(where: { $0.role == .user && $0.text == "Logged 5x5 squat" && $0.isLocalOnly }), "Expected user message to render immediately as optimistic local state")
        precondition(optimisticMessages.contains(where: \.isTyping), "Expected optimistic assistant placeholder while the request is in flight")
        precondition(viewModel.inputText.isEmpty, "Expected input to clear immediately")

        await chatService.resumeSend(
            with: .init(
                userMessageId: "server-user-1",
                assistantMessageId: "server-assistant-1",
                conversationId: "conversation-1"
            )
        )

        await sendTask.value

        let finalMessages = viewModel.messageGroups.flatMap(\.messages)
        precondition(finalMessages.count == 2, "Expected optimistic messages to reconcile with server results")
        precondition(finalMessages.contains(where: { $0.id == "server-user-1" && $0.role == .user && !$0.isLocalOnly }), "Expected optimistic user message to reconcile to server ID")
        precondition(finalMessages.contains(where: { $0.id == "server-assistant-1" && $0.role == .assistant && $0.status == .completed }), "Expected assistant message to reconcile to completed server message")
    }

    @MainActor
    private static func failedSendRestoresInputAndRemovesOptimisticMessages() async {
        let chatService = ControlledChatService()
        await chatService.setSendError(TestError.network)

        let viewModel = ChatViewModel(
            conversationId: "conversation-2",
            chatService: chatService,
            workoutService: TestWorkoutService()
        )
        viewModel.inputText = "Bench 3x8"

        await viewModel.sendMessage()

        let remainingMessages = viewModel.messageGroups.flatMap(\.messages)
        precondition(remainingMessages.isEmpty, "Expected failed optimistic messages to be removed")
        precondition(viewModel.inputText == "Bench 3x8", "Expected input text to restore after a failed send")
        precondition(viewModel.isSending == false, "Expected sending state to reset after failure")
    }
}

private enum TestError: Error {
    case network
}

private actor ControlledChatService: ChatServiceProtocol {
    var messagesToFetch: [ChatMessage] = []
    var sendError: Error?

    private var sendStarted = false
    private var sendContinuation: CheckedContinuation<SendMessageServiceResponse, Error>?
    private var sendStartedContinuation: CheckedContinuation<Void, Never>?

    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        _ = (text, sessionId)

        if let sendError {
            throw sendError
        }

        sendStarted = true
        sendStartedContinuation?.resume()
        sendStartedContinuation = nil

        return try await withCheckedThrowingContinuation { continuation in
            sendContinuation = continuation
        }
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        _ = sessionId
        return messagesToFetch
    }

    func subscribeToMessages(
        conversationId: String,
        onInsert: @escaping (ChatMessage) -> Void,
        onUpdate: @escaping (ChatMessage) -> Void
    ) async {
        _ = (conversationId, onInsert, onUpdate)
    }

    func unsubscribe() async {}

    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord {
        _ = messageId
        return workoutRecord
    }

    func waitForSendToStart() async {
        if sendStarted || sendError != nil {
            return
        }

        await withCheckedContinuation { continuation in
            sendStartedContinuation = continuation
        }
    }

    func resumeSend(with response: SendMessageServiceResponse) {
        sendContinuation?.resume(returning: response)
        sendContinuation = nil
    }

    func setMessagesToFetch(_ messages: [ChatMessage]) {
        messagesToFetch = messages
    }

    func setSendError(_ error: Error?) {
        sendError = error
    }
}

private struct TestWorkoutService: WorkoutServiceProtocol {
    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise {
        Exercise(id: exerciseId, name: name, sets: [])
    }

    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: UUID().uuidString, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}

    func deleteExercise(sessionId: String, exerciseId: String) async throws {}

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        _ = date
        return []
    }
}
