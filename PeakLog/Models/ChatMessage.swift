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

struct RunningRecordBlock: Codable, Equatable {
    let runningWorkoutId: String
    let workoutDate: String
    let durationMinutes: Int
    let distanceKm: Double
    let source: String

    enum CodingKeys: String, CodingKey {
        case runningWorkoutId = "running_workout_id"
        case workoutDate = "workout_date"
        case durationMinutes = "duration_minutes"
        case distanceKm = "distance_km"
        case source
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

struct ClarificationPromptBlock: Codable, Equatable {
    let actionType: String
    let question: String
    let draftSummary: String
    let pendingActionId: String

    enum CodingKeys: String, CodingKey {
        case actionType = "action_type"
        case question
        case draftSummary = "draft_summary"
        case pendingActionId = "pending_action_id"
    }
}

struct PlanSetBlock: Codable, Equatable, Identifiable {
    let planSetId: String
    let setIndex: Int
    let targetWeight: Double?
    let targetWeightUnit: String
    let targetReps: Int
    var completedAt: String?
    var linkedExerciseSetId: String?

    var id: String { planSetId }
    var isCompleted: Bool { completedAt != nil || linkedExerciseSetId != nil }

    enum CodingKeys: String, CodingKey {
        case planSetId = "plan_set_id"
        case setIndex = "set_index"
        case targetWeight = "target_weight"
        case targetWeightUnit = "target_weight_unit"
        case targetReps = "target_reps"
        case completedAt = "completed_at"
        case linkedExerciseSetId = "linked_exercise_set_id"
    }
}

struct PlanExerciseBlock: Codable, Equatable, Identifiable {
    let planExerciseId: String
    let orderIndex: Int
    let exerciseName: String
    let exerciseLoadType: ExerciseLoadType
    let progressionMode: String
    let notes: String?
    var sets: [PlanSetBlock]

    var id: String { planExerciseId }

    enum CodingKeys: String, CodingKey {
        case planExerciseId = "plan_exercise_id"
        case orderIndex = "order_index"
        case exerciseName = "exercise_name"
        case exerciseLoadType = "exercise_load_type"
        case progressionMode = "progression_mode"
        case notes
        case sets
    }

    init(
        planExerciseId: String,
        orderIndex: Int,
        exerciseName: String,
        exerciseLoadType: ExerciseLoadType,
        progressionMode: String,
        notes: String?,
        sets: [PlanSetBlock]
    ) {
        self.planExerciseId = planExerciseId
        self.orderIndex = orderIndex
        self.exerciseName = exerciseName
        self.exerciseLoadType = exerciseLoadType
        self.progressionMode = progressionMode
        self.notes = notes
        self.sets = sets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planExerciseId = try container.decode(String.self, forKey: .planExerciseId)
        orderIndex = try container.decode(Int.self, forKey: .orderIndex)
        exerciseName = try container.decode(String.self, forKey: .exerciseName)
        exerciseLoadType = try container.decodeIfPresent(ExerciseLoadType.self, forKey: .exerciseLoadType) ?? .unknown
        progressionMode = try container.decode(String.self, forKey: .progressionMode)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        sets = try container.decode([PlanSetBlock].self, forKey: .sets)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(planExerciseId, forKey: .planExerciseId)
        try container.encode(orderIndex, forKey: .orderIndex)
        try container.encode(exerciseName, forKey: .exerciseName)
        try container.encode(exerciseLoadType, forKey: .exerciseLoadType)
        try container.encode(progressionMode, forKey: .progressionMode)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(sets, forKey: .sets)
    }
}

struct PlanDayBlock: Codable, Equatable, Identifiable {
    let planDayId: String
    let planDate: String
    let dayIndex: Int
    let title: String
    let focus: String?
    let status: String
    var exercises: [PlanExerciseBlock]

    var id: String { planDayId }

    enum CodingKeys: String, CodingKey {
        case planDayId = "plan_day_id"
        case planDate = "plan_date"
        case dayIndex = "day_index"
        case title
        case focus
        case status
        case exercises
    }
}

struct WeeklyPlanBlock: Codable, Equatable {
    let planId: String
    let weekStartDate: String
    let goalSummary: String?
    let coachSummary: String
    let days: [PlanDayBlock]

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case weekStartDate = "week_start_date"
        case goalSummary = "goal_summary"
        case coachSummary = "coach_summary"
        case days
    }
}

struct TodayPlanBlock: Codable, Equatable {
    let planId: String
    let goalSummary: String?
    let day: PlanDayBlock

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case goalSummary = "goal_summary"
        case day
    }
}

struct PlanAdjustmentSummaryBlock: Codable, Equatable {
    let summaryText: String

    enum CodingKeys: String, CodingKey {
        case summaryText = "summary_text"
    }
}

enum ContentBlock: Equatable {
    case text(String)
    case workoutRecord(WorkoutRecordBlock)
    case workoutRecordStream(WorkoutRecordBlock)
    case runningRecord(RunningRecordBlock)
    case runningRecordStream(RunningRecordBlock)
    case prSummary(PRSummaryBlock)
    case clarificationPrompt(ClarificationPromptBlock)
    case weeklyPlan(WeeklyPlanBlock)
    case todayPlan(TodayPlanBlock)
    case planAdjustmentSummary(PlanAdjustmentSummaryBlock)
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
        case "workout_record_stream":
            let record = try WorkoutRecordBlock(from: decoder)
            self = .workoutRecordStream(record)
        case "running_record":
            let record = try RunningRecordBlock(from: decoder)
            self = .runningRecord(record)
        case "running_record_stream":
            let record = try RunningRecordBlock(from: decoder)
            self = .runningRecordStream(record)
        case "pr_summary":
            let summary = try PRSummaryBlock(from: decoder)
            self = .prSummary(summary)
        case "clarification_prompt":
            let prompt = try ClarificationPromptBlock(from: decoder)
            self = .clarificationPrompt(prompt)
        case "weekly_plan":
            let plan = try WeeklyPlanBlock(from: decoder)
            self = .weeklyPlan(plan)
        case "today_plan":
            let plan = try TodayPlanBlock(from: decoder)
            self = .todayPlan(plan)
        case "plan_adjustment_summary":
            let summary = try PlanAdjustmentSummaryBlock(from: decoder)
            self = .planAdjustmentSummary(summary)
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
        case .workoutRecordStream(let record):
            try container.encode("workout_record_stream", forKey: .type)
            try record.encode(to: encoder)
        case .runningRecord(let record):
            try container.encode("running_record", forKey: .type)
            try record.encode(to: encoder)
        case .runningRecordStream(let record):
            try container.encode("running_record_stream", forKey: .type)
            try record.encode(to: encoder)
        case .prSummary(let summary):
            try container.encode("pr_summary", forKey: .type)
            try summary.encode(to: encoder)
        case .clarificationPrompt(let prompt):
            try container.encode("clarification_prompt", forKey: .type)
            try prompt.encode(to: encoder)
        case .weeklyPlan(let plan):
            try container.encode("weekly_plan", forKey: .type)
            try plan.encode(to: encoder)
        case .todayPlan(let plan):
            try container.encode("today_plan", forKey: .type)
            try plan.encode(to: encoder)
        case .planAdjustmentSummary(let summary):
            try container.encode("plan_adjustment_summary", forKey: .type)
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
    var text: String               // plain text content (summary / fallback)
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
        role == .assistant &&
        status == .processing &&
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        contentBlocks == nil
    }

    var renderableContentBlocks: [ContentBlock] {
        (contentBlocks ?? []).filter { block in
            switch block {
            case .prSummary(let summary):
                return !summary.items.isEmpty
            default:
                return true
            }
        }
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
