import Foundation
import Supabase

// MARK: - DB Row types (match Supabase column names)

private struct MessageRow: Decodable {
    let id: String
    let conversationId: String
    let userId: String
    let role: String
    let content: String?
    let contentBlocks: [ContentBlock]?
    let status: String?
    let parseStatus: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case userId = "user_id"
        case role
        case content
        case contentBlocks = "content_blocks"
        case status
        case parseStatus = "parse_status"
        case createdAt = "created_at"
    }

    func toChatMessage() -> ChatMessage {
        ChatMessage(
            id: id,
            sessionId: conversationId,
            role: MessageRole(rawValue: role) ?? .assistant,
            text: content ?? "",
            createdAt: createdAt,
            contentBlocks: contentBlocks,
            status: MessageStatus(rawValue: status ?? ""),
            parseStatus: ParseStatus(rawValue: parseStatus ?? "")
        )
    }
}

// MARK: - Edge Function response

private struct EdgeSendMessageResponse: Decodable {
    let userMessageId: String
    let assistantMessageId: String

    enum CodingKeys: String, CodingKey {
        case userMessageId = "user_message_id"
        case assistantMessageId = "assistant_message_id"
    }
}

// MARK: - SupabaseChatService

final class SupabaseChatService: ChatServiceProtocol {
    private let supabase = SupabaseManager.shared.client
    private let streamSession: URLSession
    private var streamEventHandler: ChatServiceStreamHandler?

    init(streamSession: URLSession = .shared) {
        self.streamSession = streamSession
    }

    // MARK: - Fetch message history

    func fetchMessages(sessionId conversationId: String) async throws -> [ChatMessage] {
        let rows: [MessageRow] = try await supabase
            .from("messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
            .execute()
            .value

        return rows.map { $0.toChatMessage() }
    }

    func fetchMessages(sessionId conversationId: String, start: Date, end: Date) async throws -> [ChatMessage] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let rows: [MessageRow] = try await supabase
            .from("messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .gte("created_at", value: formatter.string(from: start))
            .lt("created_at", value: formatter.string(from: end))
            .order("created_at", ascending: true)
            .execute()
            .value

        return rows.map { $0.toChatMessage() }
    }

    // MARK: - Send message (fire-and-return; Realtime delivers the response)

    func sendMessage(_ text: String, sessionId conversationId: String) async throws -> SendMessageServiceResponse {
        let clientMessageId = UUID().uuidString
        return try await streamChatSendMessage(
            conversationId: conversationId,
            text: text,
            clientMessageId: clientMessageId,
            refreshAuth: false
        )
    }

    // MARK: - Confirm workout record (V1.5)

    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord {
        // Placeholder for V1.5 pending_confirmation flow
        return workoutRecord
    }

    // MARK: - Legacy subscription hooks

    func subscribeToMessages(
        conversationId: String,
        onInsert: @escaping (ChatMessage) -> Void,
        onUpdate: @escaping (ChatMessage) -> Void
    ) async {
        _ = (conversationId, onInsert, onUpdate)
    }

    func unsubscribe() async {
        // Chat is now driven entirely by SSE plus a final history refresh.
    }

    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        streamEventHandler = handler
    }

    // MARK: - Private helpers

    private func streamChatSendMessage(
        conversationId: String,
        text: String,
        clientMessageId: String,
        refreshAuth: Bool
    ) async throws -> SendMessageServiceResponse {
        let session = refreshAuth
            ? try await supabase.auth.refreshSession()
            : try await supabase.auth.session

        let request = try Self.makeChatSendMessageRequest(
            conversationId: conversationId,
            text: text,
            clientMessageId: clientMessageId,
            accessToken: session.accessToken
        )

        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let body = try await Self.collectData(from: bytes)
            if httpResponse.statusCode == 401, !refreshAuth {
                return try await streamChatSendMessage(
                    conversationId: conversationId,
                    text: text,
                    clientMessageId: clientMessageId,
                    refreshAuth: true
                )
            }

            throw NSError(
                domain: "PeakLog.ChatService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: Self.extractErrorMessage(from: body)]
            )
        }

        let ids = ChatStreamIDs(
            userMessageId: httpResponse.value(forHTTPHeaderField: "X-User-Message-Id") ?? clientMessageId,
            assistantMessageId: httpResponse.value(forHTTPHeaderField: "X-Assistant-Message-Id") ?? "assistant-\(clientMessageId)",
        )
        streamEventHandler?(.responseStarted(ids))

        var parser = ChatSSEParser()
        for try await line in bytes.lines {
            let chunk = line.isEmpty ? "\n" : "\(line)\n"
            let events = try parser.ingest(Data(chunk.utf8))
            for event in events {
                streamEventHandler?(event)
            }
        }

        return SendMessageServiceResponse(
            userMessageId: ids.userMessageId,
            assistantMessageId: ids.assistantMessageId,
            conversationId: conversationId
        )
    }

    private static func makeChatSendMessageRequest(
        conversationId: String,
        text: String,
        clientMessageId: String,
        accessToken: String
    ) throws -> URLRequest {
        let url = SupabaseConfig.url
            .appending(path: "functions")
            .appending(path: "v1")
            .appending(path: "chat-send-message")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "conversation_id": conversationId,
            "text": text,
            "client_message_id": clientMessageId,
        ])
        return request
    }

    private static func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }
    private static func extractErrorMessage(from data: Data) -> String {
        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? String,
            !error.isEmpty
        {
            return error
        }

        return String(data: data, encoding: .utf8) ?? "Unauthorized"
    }
}

// MARK: - AnyJSON helper

private extension AnyJSON {
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .integer(let n): return n
        case .double(let n): return n
        case .bool(let b): return b
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        case .null: return NSNull()
        }
    }
}
