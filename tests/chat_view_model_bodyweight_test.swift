import Foundation
import Combine
import CoreGraphics

@main
struct ChatViewModelBodyweightTestRunner {
    static func main() async {
        await preservesNilWeightWhenUpdatingBodyweightSets()
        print("chat_view_model_bodyweight_test passed")
    }

    @MainActor
    private static func preservesNilWeightWhenUpdatingBodyweightSets() async {
        let message = ChatMessage(
            id: "assistant-1",
            sessionId: "conversation-bodyweight",
            role: .assistant,
            text: "已记录。",
            createdAt: Date(timeIntervalSince1970: 100),
            workoutRecord: WorkoutRecord(
                id: "session-1",
                exercises: [
                    Exercise(
                        id: "exercise-1",
                        name: "Pull Up",
                        sets: [
                            ExerciseSet(
                                id: "set-1",
                                setIndex: 1,
                                weight: nil,
                                weightUnit: .kg,
                                reps: 8
                            )
                        ]
                    )
                ]
            )
        )

        let workoutService = RecordingWorkoutService()
        let viewModel = ChatViewModel(
            conversationId: "conversation-bodyweight",
            chatService: StaticChatService(messages: [message]),
            workoutService: workoutService,
            speechRecognitionService: TestSpeechRecognitionService()
        )

        await viewModel.loadMessages()

        let initialWeight = viewModel.messageGroups[0].messages[0].workoutRecord?.exercises[0].sets[0].weight
        precondition(initialWeight == nil, "Expected bodyweight set to keep nil weight when loading messages")

        await viewModel.updateSet(
            messageId: "assistant-1",
            exerciseId: "exercise-1",
            setId: "set-1",
            weight: nil,
            weightUnit: .kg,
            reps: 10
        )

        let updatedSet = viewModel.messageGroups[0].messages[0].workoutRecord?.exercises[0].sets[0]
        precondition(updatedSet?.weight == nil, "Expected bodyweight set to remain nil after editing reps")
        precondition(updatedSet?.reps == 10, "Expected reps update to be applied")

        let lastUpdate = await workoutService.lastUpdate
        precondition(lastUpdate?.weight == nil, "Expected workout service to receive nil weight for bodyweight sets")
        precondition(lastUpdate?.reps == 10, "Expected workout service to receive updated reps")
    }
}

actor StaticChatService: ChatServiceProtocol {
    let messages: [ChatMessage]

    init(messages: [ChatMessage]) {
        self.messages = messages
    }

    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        _ = (text, sessionId)
        fatalError("sendMessage should not be called in bodyweight tests")
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        _ = sessionId
        return messages
    }

    func fetchMessages(sessionId: String, start: Date, end: Date) async throws -> [ChatMessage] {
        _ = sessionId
        return messages.filter { message in
            message.createdAt >= start && message.createdAt < end
        }
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

actor RecordingWorkoutService: WorkoutServiceProtocol {
    struct UpdateCall {
        let weight: Double?
        let reps: Int
    }

    private(set) var lastUpdate: UpdateCall?

    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise {
        Exercise(id: exerciseId, name: name, sets: [])
    }

    func updateSet(
        sessionId: String,
        exerciseId: String,
        setId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet {
        _ = (sessionId, exerciseId, setId, weightUnit)
        lastUpdate = UpdateCall(weight: weight, reps: reps)
        return ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(
        sessionId: String,
        exerciseId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet {
        _ = (sessionId, exerciseId, weightUnit, reps)
        return ExerciseSet(id: UUID().uuidString, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}

    func deleteExercise(sessionId: String, exerciseId: String) async throws {}

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] { [] }
}

struct TestSpeechRecognitionService: SpeechRecognitionServicing {
    func startRecognition(
        onLevelUpdate: @escaping (CGFloat) -> Void,
        onTranscriptUpdate: @escaping (String) -> Void
    ) async throws {
        _ = onLevelUpdate
        _ = onTranscriptUpdate
    }

    func stopRecognition() async throws -> String {
        ""
    }
}

enum VoiceInputState: Equatable {
    case idle
    case recording
    case transcribing
}

protocol SpeechRecognitionServicing {
    func startRecognition(
        onLevelUpdate: @escaping (CGFloat) -> Void,
        onTranscriptUpdate: @escaping (String) -> Void
    ) async throws
    func stopRecognition() async throws -> String
}

struct SendMessageServiceResponse {
    let userMessageId: String
    let assistantMessageId: String
    let conversationId: String
}

struct ChatStreamIDs: Equatable {
    let userMessageId: String
    let assistantMessageId: String
}

enum ChatServiceStreamEvent: Equatable {
    case responseStarted(ChatStreamIDs)
    case textDelta(String)
    case workoutPreview(WorkoutRecordBlock)
    case error(String)
    case done
}

typealias ChatServiceStreamHandler = @Sendable (ChatServiceStreamEvent) -> Void

protocol ChatServiceProtocol {
    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse
    func fetchMessages(sessionId: String) async throws -> [ChatMessage]
    func fetchMessages(sessionId: String, start: Date, end: Date) async throws -> [ChatMessage]
    func subscribeToMessages(
        conversationId: String,
        onInsert: @escaping (ChatMessage) -> Void,
        onUpdate: @escaping (ChatMessage) -> Void
    ) async
    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?)
    func unsubscribe() async
    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord
}

extension ChatServiceProtocol {
    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        _ = handler
    }
}

protocol WorkoutServiceProtocol {
    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise
    func updateSet(
        sessionId: String,
        exerciseId: String,
        setId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet
    func addSet(
        sessionId: String,
        exerciseId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws
    func deleteExercise(sessionId: String, exerciseId: String) async throws
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession]
}
