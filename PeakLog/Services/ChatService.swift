import Foundation

// MARK: - Request / Response DTOs

struct SendMessageRequest: Encodable {
    let sessionId: String
    let text: String
    // V1.5: imageData, audioData (multipart)
}

struct SendMessageResponse: Decodable {
    let userMessage: ChatMessage
    let assistantMessage: ChatMessage
}

struct SendMessageServiceResponse {
    let userMessageId: String
    let assistantMessageId: String
    let conversationId: String
}

typealias ChatServiceStreamHandler = @Sendable (ChatServiceStreamEvent) -> Void

struct FetchMessagesResponse: Decodable {
    let messages: [ChatMessage]
}

// MARK: - Protocol

/// All chat-related API operations.
/// Implement `LiveChatService` to connect to the real backend.
protocol ChatServiceProtocol {
    /// Send a text message and receive the AI response with parsed workout record.
    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse

    /// Fetch the full message history for a chat session.
    func fetchMessages(sessionId: String) async throws -> [ChatMessage]

    /// Fetch message history for a specific time window.
    func fetchMessages(sessionId: String, start: Date, end: Date) async throws -> [ChatMessage]

    /// Subscribe to message inserts and updates for a conversation.
    func subscribeToMessages(
        conversationId: String,
        onInsert: @escaping (ChatMessage) -> Void,
        onUpdate: @escaping (ChatMessage) -> Void
    ) async

    /// Registers a handler for per-request SSE stream events.
    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?)

    /// Tear down any existing realtime subscription.
    func unsubscribe() async

    /// Confirm a pending workout record (low-confidence parse).
    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord
}

extension ChatServiceProtocol {
    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        _ = handler
    }
}

// MARK: - Live Implementation Stub

/// TODO: Implement real network calls using APIClient when backend is ready.
final class LiveChatService: ChatServiceProtocol {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        // TODO: POST /chat/sessions/{sessionId}/messages
        let body = SendMessageRequest(sessionId: sessionId, text: text)
        let req = try client.request(method: "POST", path: "chat/sessions/\(sessionId)/messages", body: body)
        let response: SendMessageResponse = try await client.execute(req)
        return SendMessageServiceResponse(
            userMessageId: response.userMessage.id,
            assistantMessageId: response.assistantMessage.id,
            conversationId: sessionId
        )
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        // TODO: GET /chat/sessions/{sessionId}/messages
        let req = try client.request(path: "chat/sessions/\(sessionId)/messages")
        let res: FetchMessagesResponse = try await client.execute(req)
        return res.messages
    }

    func fetchMessages(sessionId: String, start: Date, end: Date) async throws -> [ChatMessage] {
        try await fetchMessages(sessionId: sessionId).filter { message in
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

    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        _ = handler
    }

    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord {
        // TODO: PATCH /chat/messages/{messageId}/confirm
        struct ConfirmBody: Encodable { let workoutRecord: WorkoutRecord }
        let req = try client.request(method: "PATCH", path: "chat/messages/\(messageId)/confirm", body: ConfirmBody(workoutRecord: workoutRecord))
        return try await client.execute(req)
    }
}

// MARK: - Mock Implementation (for previews and development)

final class MockChatService: ChatServiceProtocol {
    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        try await Task.sleep(nanoseconds: 800_000_000) // simulate latency
        let now = Date()
        let userId = UUID().uuidString
        let aiId = UUID().uuidString

        let userMsg = ChatMessage(id: userId, sessionId: sessionId, role: .user, text: text, createdAt: now)

        let record = WorkoutRecord(
            id: UUID().uuidString,
            exercises: MockData.sampleExercises
        )
        var aiMsg = ChatMessage(
            id: aiId,
            sessionId: sessionId,
            role: .assistant,
            text: "Added! That's a solid pull. 💪 Here's the record:",
            createdAt: now.addingTimeInterval(1)
        )
        aiMsg.workoutRecord = record
        aiMsg.parseStatus = .completed

        return SendMessageServiceResponse(
            userMessageId: userMsg.id,
            assistantMessageId: aiMsg.id,
            conversationId: sessionId
        )
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        return MockData.sampleMessages(sessionId: sessionId)
    }

    func fetchMessages(sessionId: String, start: Date, end: Date) async throws -> [ChatMessage] {
        try await fetchMessages(sessionId: sessionId).filter { message in
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

    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        _ = handler
    }

    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord {
        return workoutRecord
    }
}

// MARK: - Mock Data
enum MockData {
    static let benchPress = Exercise(
        id: "ex-1",
        name: "Bench Press",
        sets: [
            ExerciseSet(id: "s-1", setIndex: 1, weight: 80, weightUnit: .kg, reps: 10),
            ExerciseSet(id: "s-2", setIndex: 2, weight: 80, weightUnit: .kg, reps: 10),
            ExerciseSet(id: "s-3", setIndex: 3, weight: 80, weightUnit: .kg, reps: 10),
        ]
    )

    static let squat = Exercise(
        id: "ex-2",
        name: "Squat",
        sets: [
            ExerciseSet(id: "s-4", setIndex: 1, weight: 100, weightUnit: .kg, reps: 8),
            ExerciseSet(id: "s-5", setIndex: 2, weight: 100, weightUnit: .kg, reps: 8),
            ExerciseSet(id: "s-6", setIndex: 3, weight: 100, weightUnit: .kg, reps: 8),
        ]
    )

    static let deadlift = Exercise(
        id: "ex-3",
        name: "Deadlift",
        sets: [
            ExerciseSet(id: "s-7", setIndex: 1, weight: 120, weightUnit: .kg, reps: 5),
        ]
    )

    static var sampleExercises: [Exercise] { [benchPress, squat, deadlift] }

    static func sampleMessages(sessionId: String) -> [ChatMessage] {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let now = Date()

        var greetMsg = ChatMessage(
            id: "m-1", sessionId: sessionId, role: .assistant,
            text: "Hey! 👋 I'm your AI Gym Logger. Tell me what you did at the gym today and I'll log it for you!",
            createdAt: yesterday
        )
        greetMsg.parseStatus = .completed

        let userMsg1 = ChatMessage(
            id: "m-2", sessionId: sessionId, role: .user,
            text: "I did 3 sets of bench press, 80kg for 10 reps, then 3 sets of squats 100kg for 8 reps",
            createdAt: yesterday.addingTimeInterval(60)
        )

        var aiMsg1 = ChatMessage(
            id: "m-3", sessionId: sessionId, role: .assistant,
            text: "Nice session! Here's what I logged:",
            createdAt: yesterday.addingTimeInterval(62)
        )
        aiMsg1.workoutRecord = WorkoutRecord(id: "wr-1", exercises: [benchPress, squat])
        aiMsg1.parseStatus = .completed

        let userMsg2 = ChatMessage(
            id: "m-4", sessionId: sessionId, role: .user,
            text: "Also did a set of deadlifts, 120kg for 5 reps",
            createdAt: now.addingTimeInterval(-120)
        )

        var aiMsg2 = ChatMessage(
            id: "m-5", sessionId: sessionId, role: .assistant,
            text: "Added! That's a solid pull. 💪 Here's the record:",
            createdAt: now.addingTimeInterval(-118)
        )
        aiMsg2.workoutRecord = WorkoutRecord(id: "wr-2", exercises: [deadlift])
        aiMsg2.parseStatus = .completed

        return [greetMsg, userMsg1, aiMsg1, userMsg2, aiMsg2]
    }
}
