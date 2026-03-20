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
    private var realtimeChannel: RealtimeChannelV2?

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

    // MARK: - Send message (fire-and-return; Realtime delivers the response)

    func sendMessage(_ text: String, sessionId conversationId: String) async throws -> SendMessageServiceResponse {
        let clientMessageId = UUID().uuidString
        let response = try await invokeChatSendMessage(
            conversationId: conversationId,
            text: text,
            clientMessageId: clientMessageId,
            refreshAuth: false
        )

        // Return the IDs immediately. The actual assistant content arrives
        // via Realtime when the background processing completes.
        return SendMessageServiceResponse(
            userMessageId: response.userMessageId,
            assistantMessageId: response.assistantMessageId,
            conversationId: conversationId
        )
    }

    // MARK: - Confirm workout record (V1.5)

    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord {
        // Placeholder for V1.5 pending_confirmation flow
        return workoutRecord
    }

    // MARK: - Realtime subscription

    /// Subscribe to all INSERT and UPDATE events on messages for a given conversation.
    /// `onInsert` fires with the new typing-bubble placeholder.
    /// `onUpdate` fires with processing/completed/failed assistant updates.
    func subscribeToMessages(
        conversationId: String,
        onInsert: @escaping (ChatMessage) -> Void,
        onUpdate: @escaping (ChatMessage) -> Void
    ) async {
        await unsubscribe()

        let channel = supabase.channel("messages:\(conversationId)")

        channel.onPostgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages",
            filter: "conversation_id=eq.\(conversationId)"
        ) { payload in
            guard let row = Self.decodeMessageRow(from: payload.record) else { return }
            onInsert(row.toChatMessage())
        }

        channel.onPostgresChange(
            UpdateAction.self,
            schema: "public",
            table: "messages",
            filter: "conversation_id=eq.\(conversationId)"
        ) { payload in
            guard let row = Self.decodeMessageRow(from: payload.record) else { return }
            if row.role == "assistant" && (row.status == "processing" || row.status == "completed" || row.status == "failed") {
                onUpdate(row.toChatMessage())
            }
        }

        await channel.subscribe()
        realtimeChannel = channel
    }

    func unsubscribe() async {
        if let channel = realtimeChannel {
            await supabase.removeChannel(channel)
            realtimeChannel = nil
        }
    }

    // MARK: - Private helpers

    private func invokeChatSendMessage(
        conversationId: String,
        text: String,
        clientMessageId: String,
        refreshAuth: Bool
    ) async throws -> EdgeSendMessageResponse {
        let session = refreshAuth ? try await supabase.auth.refreshSession() : try await supabase.auth.session
        supabase.functions.setAuth(token: session.accessToken)

        do {
            return try await supabase.functions.invoke(
                "chat-send-message",
                options: FunctionInvokeOptions(
                    body: [
                        "conversation_id": conversationId,
                        "text": text,
                        "client_message_id": clientMessageId
                    ]
                )
            )
        } catch let error as FunctionsError {
            if case let .httpError(code, data) = error, code == 401 {
                let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"
                print("chat-send-message unauthorized: \(body)")

                if !refreshAuth {
                    // Force a refresh once in case the local session exists but the access token
                    // has gone stale or the functions client has not yet observed the latest auth
                    // event.
                    return try await invokeChatSendMessage(
                        conversationId: conversationId,
                        text: text,
                        clientMessageId: clientMessageId,
                        refreshAuth: true
                    )
                }

                throw NSError(
                    domain: "PeakLog.ChatService",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: Self.extractErrorMessage(from: data)]
                )
            }

            throw error
        }
    }

    private static func decodeMessageRow(from record: [String: AnyJSON]?) -> MessageRow? {
        guard let record else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try record.decode(as: MessageRow.self, decoder: decoder)
        } catch {
            print("Failed to decode MessageRow from Realtime payload: \(error)")
            return nil
        }
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
