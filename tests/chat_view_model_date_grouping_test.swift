import Foundation
import Combine
import CoreGraphics

@main
struct ChatViewModelDateGroupingTestRunner {
    static func main() async {
        await groupsTodayMessagesUnderTodayLabel()
        await rendersHistoricalMessagesAsAbsoluteDates()
        await keepsMessagesFromSameDayInOneGroupAndOrdersGroupsChronologically()
        print("chat_view_model_date_grouping_test passed")
    }

    @MainActor
    private static func groupsTodayMessagesUnderTodayLabel() async {
        let calendar = Calendar.current
        let now = Date()
        let messages = [
            ChatMessage(
                id: "today-1",
                sessionId: "conversation-today",
                role: .assistant,
                text: "Today's message",
                createdAt: calendar.date(byAdding: .minute, value: -5, to: now) ?? now
            )
        ]

        let viewModel = makeViewModel(conversationId: "conversation-today", messages: messages)
        await viewModel.loadMessages()

        precondition(viewModel.messageGroups.count == 1, "Expected a single date group for today's messages")
        precondition(viewModel.messageGroups[0].label == "Today", "Expected today's messages to render under the Today label")
    }

    @MainActor
    private static func rendersHistoricalMessagesAsAbsoluteDates() async {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        let messages = [
            ChatMessage(
                id: "yesterday-1",
                sessionId: "conversation-history",
                role: .assistant,
                text: "Yesterday's message",
                createdAt: yesterday
            )
        ]

        let viewModel = makeViewModel(conversationId: "conversation-history", messages: messages)
        await viewModel.loadMessages()

        precondition(viewModel.messageGroups.count == 1, "Expected a single historical date group")
        let label = viewModel.messageGroups[0].label
        precondition(label != "Yesterday", "Expected historical messages to use an absolute date label instead of Yesterday")
        precondition(label == localizedShortDate(yesterday), "Expected historical messages to use the localized short date label")
    }

    @MainActor
    private static func keepsMessagesFromSameDayInOneGroupAndOrdersGroupsChronologically() async {
        let calendar = Calendar.current
        let now = Date()
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now) ?? now.addingTimeInterval(-172_800)
        let twoDaysAgoLater = calendar.date(byAdding: .hour, value: 2, to: twoDaysAgo) ?? twoDaysAgo
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)

        let messages = [
            ChatMessage(
                id: "day-2-first",
                sessionId: "conversation-order",
                role: .user,
                text: "Two days ago first",
                createdAt: twoDaysAgo
            ),
            ChatMessage(
                id: "today-1",
                sessionId: "conversation-order",
                role: .assistant,
                text: "Today",
                createdAt: now
            ),
            ChatMessage(
                id: "day-2-second",
                sessionId: "conversation-order",
                role: .assistant,
                text: "Two days ago second",
                createdAt: twoDaysAgoLater
            ),
            ChatMessage(
                id: "yesterday-1",
                sessionId: "conversation-order",
                role: .user,
                text: "Yesterday",
                createdAt: yesterday
            )
        ]

        let viewModel = makeViewModel(conversationId: "conversation-order", messages: messages)
        await viewModel.loadMessages()

        let groups = viewModel.messageGroups
        precondition(groups.count == 3, "Expected messages across three days to create three groups")
        precondition(groups[0].label == localizedShortDate(twoDaysAgo), "Expected the earliest group to be the oldest absolute date")
        precondition(groups[0].messages.count == 2, "Expected messages from the same day to stay in one group")
        precondition(groups[1].label == localizedShortDate(yesterday), "Expected the middle group to be yesterday's absolute date")
        precondition(groups[2].label == "Today", "Expected the latest group to be Today")
    }

    @MainActor
    private static func makeViewModel(conversationId: String, messages: [ChatMessage]) -> ChatViewModel {
        ChatViewModel(
            conversationId: conversationId,
            chatService: StaticChatService(messages: messages),
            workoutService: TestWorkoutService(),
            speechRecognitionService: TestSpeechRecognitionService()
        )
    }

    private static func localizedShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

actor StaticChatService: ChatServiceProtocol {
    let messages: [ChatMessage]

    init(messages: [ChatMessage]) {
        self.messages = messages
    }

    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        _ = (text, sessionId)
        fatalError("sendMessage should not be called in date grouping tests")
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        _ = sessionId
        return messages
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

struct TestWorkoutService: WorkoutServiceProtocol {
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

protocol ChatServiceProtocol {
    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse
    func fetchMessages(sessionId: String) async throws -> [ChatMessage]
    func subscribeToMessages(
        conversationId: String,
        onInsert: @escaping (ChatMessage) -> Void,
        onUpdate: @escaping (ChatMessage) -> Void
    ) async
    func unsubscribe() async
    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord
}

protocol WorkoutServiceProtocol {
    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func addSet(sessionId: String, exerciseId: String, weight: Double, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws
    func deleteExercise(sessionId: String, exerciseId: String) async throws
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession]
}
