import Foundation
import Combine
import CoreGraphics

@main
struct ChatViewModelDayPaginationTestRunner {
    private static let todayLabel = String(localized: "common.today")

    static func main() async {
        await loadsOnlyTodayOnFirstAppear()
        await keepsScreenBlankWhenTodayHasNoMessages()
        await loadsPreviousDayWhenUserRequestsOlderHistory()
        await skipsEmptyDaysWhenLoadingOlderHistory()
        await stopsLoadingWhenNoOlderHistoryExists()
        print("chat_view_model_day_pagination_test passed")
    }

    @MainActor
    private static func loadsOnlyTodayOnFirstAppear() async {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)

        let service = WindowedChatService(messages: [
            ChatMessage(
                id: "yesterday-1",
                sessionId: "conversation-today-only",
                role: .assistant,
                text: "Yesterday",
                createdAt: yesterday
            ),
            ChatMessage(
                id: "today-1",
                sessionId: "conversation-today-only",
                role: .assistant,
                text: "Today",
                createdAt: now
            )
        ])

        let viewModel = makeViewModel(
            conversationId: "conversation-today-only",
            chatService: service
        )

        await viewModel.onAppear()

        precondition(viewModel.hasLoadedInitialDay, "Expected the view model to finish initial day loading")
        precondition(viewModel.messageGroups.count == 1, "Expected only today's group on first load")
        precondition(viewModel.messageGroups[0].label == todayLabel, "Expected first load to show only today's label")
        precondition(viewModel.messageGroups[0].messages.map(\.id) == ["today-1"], "Expected only today's messages to render initially")
        precondition(viewModel.shouldScrollToBottomOnce, "Expected initial load with today's messages to request a one-time scroll to bottom")
    }

    @MainActor
    private static func keepsScreenBlankWhenTodayHasNoMessages() async {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)

        let viewModel = makeViewModel(
            conversationId: "conversation-blank",
            chatService: WindowedChatService(messages: [
                ChatMessage(
                    id: "yesterday-1",
                    sessionId: "conversation-blank",
                    role: .assistant,
                    text: "Yesterday",
                    createdAt: yesterday
                )
            ])
        )

        await viewModel.onAppear()

        precondition(viewModel.hasLoadedInitialDay, "Expected initial load to complete even without today's messages")
        precondition(viewModel.messageGroups.isEmpty, "Expected an empty chat list when today has no messages")
        precondition(viewModel.shouldScrollToBottomOnce == false, "Expected blank state to avoid any auto-scroll request")
    }

    @MainActor
    private static func loadsPreviousDayWhenUserRequestsOlderHistory() async {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)

        let viewModel = makeViewModel(
            conversationId: "conversation-history",
            chatService: WindowedChatService(messages: [
                ChatMessage(
                    id: "yesterday-1",
                    sessionId: "conversation-history",
                    role: .assistant,
                    text: "Yesterday",
                    createdAt: yesterday
                ),
                ChatMessage(
                    id: "today-1",
                    sessionId: "conversation-history",
                    role: .user,
                    text: "Today",
                    createdAt: now
                )
            ])
        )

        await viewModel.onAppear()
        await viewModel.loadPreviousDayIfNeeded(anchorMessageID: "today-1")

        precondition(viewModel.messageGroups.count == 2, "Expected one older day to be prepended")
        precondition(viewModel.messageGroups[0].messages.map(\.id) == ["yesterday-1"], "Expected yesterday to load above today")
        precondition(viewModel.pendingTopAnchorMessageID == "today-1", "Expected top anchor to preserve scroll position after prepending history")
    }

    @MainActor
    private static func skipsEmptyDaysWhenLoadingOlderHistory() async {
        let calendar = Calendar.current
        let now = Date()
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now) ?? now.addingTimeInterval(-172_800)

        let viewModel = makeViewModel(
            conversationId: "conversation-skip-empty",
            chatService: WindowedChatService(messages: [
                ChatMessage(
                    id: "two-days-ago-1",
                    sessionId: "conversation-skip-empty",
                    role: .assistant,
                    text: "Two days ago",
                    createdAt: twoDaysAgo
                ),
                ChatMessage(
                    id: "today-1",
                    sessionId: "conversation-skip-empty",
                    role: .user,
                    text: "Today",
                    createdAt: now
                )
            ])
        )

        await viewModel.onAppear()
        await viewModel.loadPreviousDayIfNeeded(anchorMessageID: "today-1")

        precondition(viewModel.messageGroups.count == 2, "Expected an older non-empty day to load even if yesterday is empty")
        precondition(viewModel.messageGroups[0].messages.map(\.id) == ["two-days-ago-1"], "Expected the loader to skip empty days and find the next non-empty date")
    }

    @MainActor
    private static func stopsLoadingWhenNoOlderHistoryExists() async {
        let now = Date()
        let viewModel = makeViewModel(
            conversationId: "conversation-end",
            chatService: WindowedChatService(messages: [
                ChatMessage(
                    id: "today-1",
                    sessionId: "conversation-end",
                    role: .assistant,
                    text: "Today",
                    createdAt: now
                )
            ])
        )

        await viewModel.onAppear()
        await viewModel.loadPreviousDayIfNeeded(anchorMessageID: "today-1")

        precondition(viewModel.hasMoreHistory == false, "Expected hasMoreHistory to turn false after exhausting older history")
        precondition(viewModel.messageGroups.count == 1, "Expected no extra groups when there is no older history")
    }

    @MainActor
    private static func makeViewModel(
        conversationId: String,
        chatService: WindowedChatService
    ) -> ChatViewModel {
        ChatViewModel(
            conversationId: conversationId,
            chatService: chatService,
            workoutService: TestWorkoutService(),
            speechRecognitionService: TestSpeechRecognitionService()
        )
    }
}

private actor WindowedChatService: ChatServiceProtocol {
    let messages: [ChatMessage]

    init(messages: [ChatMessage]) {
        self.messages = messages
    }

    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        _ = (text, sessionId)
        fatalError("sendMessage should not be called in day pagination tests")
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        messages
            .filter { $0.sessionId == sessionId }
            .sorted(by: { $0.createdAt < $1.createdAt })
    }

    func fetchMessages(sessionId: String, start: Date, end: Date) async throws -> [ChatMessage] {
        messages
            .filter { message in
                message.sessionId == sessionId &&
                message.createdAt >= start &&
                message.createdAt < end
            }
            .sorted(by: { $0.createdAt < $1.createdAt })
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

private struct TestWorkoutService: WorkoutServiceProtocol {
    func updateExerciseName(sessionId: String, exerciseId: String, name: String) async throws -> Exercise {
        Exercise(id: exerciseId, name: name, sets: [])
    }

    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
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
    func updateSet(sessionId: String, exerciseId: String, setId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet
    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws
    func deleteExercise(sessionId: String, exerciseId: String) async throws
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession]
}
