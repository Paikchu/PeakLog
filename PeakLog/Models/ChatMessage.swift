import Foundation

// MARK: - Message Role
enum MessageRole: String, Codable {
    case user
    case assistant
}

// MARK: - Message Parse Status
enum ParseStatus: String, Codable {
    case processing   // AI is working
    case completed    // Successfully parsed
    case failed       // Parsing failed
    case pendingConfirmation = "pending_confirmation" // Low confidence, needs user confirmation
}

// MARK: - Chat Message
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let sessionId: String
    let role: MessageRole
    let text: String
    let createdAt: Date

    /// Non-nil when this AI message produced a workout record
    var workoutRecord: WorkoutRecord?

    /// Parsing status for AI messages
    var parseStatus: ParseStatus?

    // MARK: - Attachment placeholders (V1.5)
    var imageURL: URL?
    var audioURL: URL?
}

// MARK: - Date Group (for chat date separators)
struct MessageGroup: Identifiable, Equatable {
    var id: String { label }
    let label: String        // "Today", "Yesterday", "Mar 17", …
    var messages: [ChatMessage]
}

// MARK: - Workout Record (embedded in an AI message)
struct WorkoutRecord: Identifiable, Codable, Equatable {
    let id: String
    var exercises: [Exercise]
}
