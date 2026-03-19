import Foundation

// MARK: - Message Role

enum MessageRole: String, Codable {
    case user
    case assistant
}

// MARK: - Message Parse Status

enum ParseStatus: String, Codable {
    case processing
    case completed
    case failed
    case pendingConfirmation = "pending_confirmation"
}

// MARK: - Message Status

enum MessageStatus: String, Codable {
    case created
    case processing
    case completed
    case failed
}

// MARK: - ContentBlock
// GenUI content blocks: the AI reply is an ordered array of typed blocks.
// iOS renders each block as a different SwiftUI component.

struct ContentBlockSet: Codable, Equatable {
    let setId: String
    let setIndex: Int
    let weight: Double?
    let weightUnit: String
    let reps: Int?

    enum CodingKeys: String, CodingKey {
        case setId = "set_id"
        case setIndex = "set_index"
        case weight
        case weightUnit = "weight_unit"
        case reps
    }
}

struct ContentBlockExercise: Codable, Equatable {
    let exerciseId: String
    let name: String
    let orderIndex: Int
    let sets: [ContentBlockSet]

    enum CodingKeys: String, CodingKey {
        case exerciseId = "exercise_id"
        case name
        case orderIndex = "order_index"
        case sets
    }
}

struct WorkoutRecordBlock: Codable, Equatable {
    let workoutSessionId: String
    let workoutDate: String
    let title: String?
    let parseStatus: String
    let exercises: [ContentBlockExercise]

    enum CodingKeys: String, CodingKey {
        case workoutSessionId = "workout_session_id"
        case workoutDate = "workout_date"
        case title
        case parseStatus = "parse_status"
        case exercises
    }
}

struct PRSummaryItem: Codable, Equatable {
    let normalizedName: String
    let displayName: String
    let previousWeight: Double?
    let currentWeight: Double
    let weightUnit: String
    let isNewRecord: Bool

    enum CodingKeys: String, CodingKey {
        case normalizedName = "normalized_name"
        case displayName = "display_name"
        case previousWeight = "previous_weight"
        case currentWeight = "current_weight"
        case weightUnit = "weight_unit"
        case isNewRecord = "is_new_record"
    }
}

struct PRSummaryBlock: Codable, Equatable {
    let summaryText: String
    let items: [PRSummaryItem]

    enum CodingKeys: String, CodingKey {
        case summaryText = "summary_text"
        case items
    }
}

enum ContentBlock: Equatable {
    case text(String)
    case workoutRecord(WorkoutRecordBlock)
    case prSummary(PRSummaryBlock)
    case unknown
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "workout_record":
            let record = try WorkoutRecordBlock(from: decoder)
            self = .workoutRecord(record)
        case "pr_summary":
            let summary = try PRSummaryBlock(from: decoder)
            self = .prSummary(summary)
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .workoutRecord(let record):
            try container.encode("workout_record", forKey: .type)
            try record.encode(to: encoder)
        case .prSummary(let summary):
            try container.encode("pr_summary", forKey: .type)
            try summary.encode(to: encoder)
        case .unknown:
            try container.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let sessionId: String          // maps to conversation_id in DB
    let role: MessageRole
    let text: String               // plain text content (summary / fallback)
    let createdAt: Date

    /// GenUI content blocks — prefer this over `workoutRecord` when non-nil.
    /// Populated from messages.content_blocks (jsonb).
    var contentBlocks: [ContentBlock]?

    /// Message processing status — drives typing bubble vs completed card.
    var status: MessageStatus?

    /// Legacy field kept for mock data / previews backward compat.
    var workoutRecord: WorkoutRecord?

    /// Parsing status for AI messages
    var parseStatus: ParseStatus?

    /// Tracks optimistic local messages until the server copy is observed.
    var isLocalOnly: Bool = false

    // V1.5 attachment placeholders
    var imageURL: URL?
    var audioURL: URL?

    /// Convenience: true when this is a processing placeholder (typing bubble)
    var isTyping: Bool {
        role == .assistant && status == .processing && contentBlocks == nil
    }

    // MARK: Codable mapping from Supabase column names

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "conversation_id"
        case role
        case text = "content"
        case createdAt = "created_at"
        case contentBlocks = "content_blocks"
        case status
        case parseStatus = "parse_status"
    }

    init(
        id: String,
        sessionId: String,
        role: MessageRole,
        text: String,
        createdAt: Date,
        contentBlocks: [ContentBlock]? = nil,
        status: MessageStatus? = nil,
        workoutRecord: WorkoutRecord? = nil,
        parseStatus: ParseStatus? = nil,
        isLocalOnly: Bool = false,
        imageURL: URL? = nil,
        audioURL: URL? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.contentBlocks = contentBlocks
        self.status = status
        self.workoutRecord = workoutRecord
        self.parseStatus = parseStatus
        self.isLocalOnly = isLocalOnly
        self.imageURL = imageURL
        self.audioURL = audioURL
    }
}

// MARK: - Date Group (for chat date separators)

struct MessageGroup: Identifiable, Equatable {
    var id: String { label }
    let label: String
    var messages: [ChatMessage]
}

// MARK: - Workout Record (legacy, used by mock data and previews)

struct WorkoutRecord: Identifiable, Codable, Equatable {
    let id: String
    var exercises: [Exercise]
}
