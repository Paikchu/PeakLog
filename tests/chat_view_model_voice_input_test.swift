import Foundation
import Combine
import CoreGraphics

@main
struct ChatViewModelVoiceInputTestRunner {
    static func main() async {
        await toggleVoiceInputStartsRecordingWhenIdle()
        await liveTranscriptionUpdatesTheInputWhileRecording()
        await toggleVoiceInputStopsRecordingAndRestoresIdleAfterTranscription()
        await failedTranscriptionRestoresIdleAndPreservesExistingInput()
        await voiceInputDoesNotStartWhileSending()
        print("chat_view_model_voice_input_test passed")
    }

    @MainActor
    private static func toggleVoiceInputStartsRecordingWhenIdle() async {
        let speechService = ControlledSpeechRecognitionService()
        let viewModel = ChatViewModel(
            conversationId: "conversation-voice-1",
            chatService: IdleChatService(),
            workoutService: TestWorkoutService(),
            speechRecognitionService: speechService
        )

        await viewModel.toggleVoiceInput()

        precondition(viewModel.voiceInputState == .recording, "Expected voice input to enter recording state")
        precondition(viewModel.isVoiceInteractionEnabled, "Expected voice interaction to remain enabled while recording")
    }

    @MainActor
    private static func liveTranscriptionUpdatesTheInputWhileRecording() async {
        let speechService = ControlledSpeechRecognitionService()
        let viewModel = ChatViewModel(
            conversationId: "conversation-voice-live",
            chatService: IdleChatService(),
            workoutService: TestWorkoutService(),
            speechRecognitionService: speechService
        )

        await viewModel.toggleVoiceInput()
        await speechService.emitTranscript("记录")
        precondition(viewModel.inputText == "记录", "Expected partial speech recognition to populate the input while recording")

        await speechService.emitTranscript("记录今天的训练")
        precondition(viewModel.inputText == "记录今天的训练", "Expected later partial speech recognition to replace the draft in real time")
    }

    @MainActor
    private static func toggleVoiceInputStopsRecordingAndRestoresIdleAfterTranscription() async {
        let speechService = ControlledSpeechRecognitionService()
        let viewModel = ChatViewModel(
            conversationId: "conversation-voice-2",
            chatService: IdleChatService(),
            workoutService: TestWorkoutService(),
            speechRecognitionService: speechService
        )

        await viewModel.toggleVoiceInput()
        await speechService.emitLevel(0.42)

        let stopTask = Task {
            await viewModel.toggleVoiceInput()
        }

        await speechService.emitTranscript("Log bench press 3 by 8")
        await speechService.waitForStop()
        precondition(viewModel.voiceInputState == .transcribing, "Expected second toggle to switch into transcribing state")
        precondition(viewModel.inputText == "Log bench press 3 by 8", "Expected partial speech recognition to already be visible before final transcription finishes")

        await speechService.finish(with: "Log bench press 3 by 8")
        await stopTask.value

        precondition(viewModel.voiceInputState == .idle, "Expected voice input to return to idle after transcription")
        precondition(viewModel.inputText == "Log bench press 3 by 8", "Expected transcription to populate the input text")
        precondition(viewModel.errorMessage == nil, "Expected no error after successful transcription")
    }

    @MainActor
    private static func failedTranscriptionRestoresIdleAndPreservesExistingInput() async {
        let speechService = ControlledSpeechRecognitionService()
        let viewModel = ChatViewModel(
            conversationId: "conversation-voice-3",
            chatService: IdleChatService(),
            workoutService: TestWorkoutService(),
            speechRecognitionService: speechService
        )
        viewModel.inputText = "Existing draft"

        await viewModel.toggleVoiceInput()
        await speechService.emitTranscript("replace this draft")
        let stopTask = Task {
            await viewModel.toggleVoiceInput()
        }

        await speechService.waitForStop()
        await speechService.fail(with: TestVoiceError.transcriptionFailed)
        await stopTask.value

        precondition(viewModel.voiceInputState == .idle, "Expected failed transcription to restore idle state")
        precondition(viewModel.inputText == "Existing draft", "Expected failed transcription to preserve existing input")
        precondition(viewModel.errorMessage == TestVoiceError.transcriptionFailed.localizedDescription, "Expected failed transcription to surface an error message")
    }

    @MainActor
    private static func voiceInputDoesNotStartWhileSending() async {
        let speechService = ControlledSpeechRecognitionService()
        let viewModel = ChatViewModel(
            conversationId: "conversation-voice-4",
            chatService: IdleChatService(),
            workoutService: TestWorkoutService(),
            speechRecognitionService: speechService
        )
        viewModel.isSending = true

        await viewModel.toggleVoiceInput()

        precondition(viewModel.voiceInputState == .idle, "Expected voice input to remain idle while a message is sending")
        let starts = await speechService.startCount
        precondition(starts == 0, "Expected speech recognition not to start while sending")
    }
}

private enum TestVoiceError: LocalizedError {
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed:
            return "Speech transcription failed."
        }
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

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] { [] }
}

private actor ControlledSpeechRecognitionService: SpeechRecognitionServicing {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    private var onLevel: ((CGFloat) -> Void)?
    private var onTranscript: ((String) -> Void)?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<String, Error>?

    func startRecognition(
        onLevelUpdate: @escaping (CGFloat) -> Void,
        onTranscriptUpdate: @escaping (String) -> Void
    ) async throws {
        startCount += 1
        onLevel = onLevelUpdate
        onTranscript = onTranscriptUpdate
    }

    func stopRecognition() async throws -> String {
        stopCount += 1
        stopContinuation?.resume()
        stopContinuation = nil

        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func emitLevel(_ level: CGFloat) {
        onLevel?(level)
    }

    func emitTranscript(_ text: String) {
        onTranscript?(text)
    }

    func waitForStop() async {
        if stopCount > 0 {
            return
        }

        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func finish(with text: String) {
        resultContinuation?.resume(returning: text)
        resultContinuation = nil
    }

    func fail(with error: Error) {
        resultContinuation?.resume(throwing: error)
        resultContinuation = nil
    }
}

private actor IdleChatService: ChatServiceProtocol {
    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        _ = (text, sessionId)
        fatalError("sendMessage should not be called in voice input tests")
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        _ = sessionId
        return []
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
}
