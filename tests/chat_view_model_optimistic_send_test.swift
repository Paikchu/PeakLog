import Foundation
import Combine
import CoreGraphics

@main
struct ChatViewModelOptimisticSendTestRunner {
    static func main() async {
        await sentMessageAppearsImmediatelyBeforeNetworkReturns()
        await processingAssistantUpdateReplacesOptimisticPlaceholder()
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
            workoutService: TestWorkoutService(),
            speechRecognitionService: TestSpeechRecognitionService()
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
            workoutService: TestWorkoutService(),
            speechRecognitionService: TestSpeechRecognitionService()
        )
        viewModel.inputText = "Bench 3x8"

        await viewModel.sendMessage()

        let remainingMessages = viewModel.messageGroups.flatMap(\.messages)
        precondition(remainingMessages.isEmpty, "Expected failed optimistic messages to be removed")
        precondition(viewModel.inputText == "Bench 3x8", "Expected input text to restore after a failed send")
        precondition(viewModel.isSending == false, "Expected sending state to reset after failure")
    }

    @MainActor
    private static func processingAssistantUpdateReplacesOptimisticPlaceholder() async {
        let chatService = ControlledChatService()

        let viewModel = ChatViewModel(
            conversationId: "conversation-3",
            chatService: chatService,
            workoutService: TestWorkoutService(),
            speechRecognitionService: TestSpeechRecognitionService()
        )

        await viewModel.onAppear()
        viewModel.inputText = "Logged deadlift"

        let sendTask = Task {
            await viewModel.sendMessage()
        }

        await chatService.waitForSendToStart()
        await Task.yield()

        await chatService.resumeSend(
            with: .init(
                userMessageId: "server-user-3",
                assistantMessageId: "server-assistant-3",
                conversationId: "conversation-3"
            )
        )

        await chatService.emitUpdate(
            ChatMessage(
                id: "server-assistant-3",
                sessionId: "conversation-3",
                role: .assistant,
                text: "Streaming partial reply",
                createdAt: Date(timeIntervalSince1970: 200),
                status: .processing
            )
        )
        await Task.yield()

        let messages = viewModel.messageGroups.flatMap(\.messages)
        let assistant = messages.first { $0.id == "server-assistant-3" }
        precondition(assistant?.text == "Streaming partial reply", "Expected processing update text to replace optimistic placeholder")
        precondition(assistant?.isTyping == false, "Expected processing assistant with text to stop rendering as typing-only")
        precondition(viewModel.isSending == true, "Expected sending state to remain true while assistant is processing")

        await chatService.emitUpdate(
            ChatMessage(
                id: "server-assistant-3",
                sessionId: "conversation-3",
                role: .assistant,
                text: "Streaming partial reply",
                createdAt: Date(timeIntervalSince1970: 201),
                contentBlocks: [.text("Streaming partial reply")],
                status: .completed
            )
        )

        await sendTask.value
        precondition(viewModel.isSending == false, "Expected sending state to stop after assistant completion")
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
    private var onInsert: ((ChatMessage) -> Void)?
    private var onUpdate: ((ChatMessage) -> Void)?

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
        _ = conversationId
        self.onInsert = onInsert
        self.onUpdate = onUpdate
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

    func emitInsert(_ message: ChatMessage) {
        onInsert?(message)
    }

    func emitUpdate(_ message: ChatMessage) {
        onUpdate?(message)
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

private struct TestSpeechRecognitionService: SpeechRecognitionServicing {
    func startRecognition(onLevelUpdate: @escaping (CGFloat) -> Void) async throws {
        _ = onLevelUpdate
    }

    func stopRecognition() async throws -> String {
        ""
    }
}
