import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct SendMessageServiceResponse {
    let userMessageId: String
    let assistantMessageId: String
    let conversationId: String
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

final class OnDeviceChatService: ChatServiceProtocol {
    private let database: LocalAppDatabase
    private let modelEngine = OnDeviceCoachModelEngine()
    private var streamHandler: ChatServiceStreamHandler?

    init(database: LocalAppDatabase) {
        self.database = database
    }

    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        let now = Date()
        let userMessageId = UUID().uuidString
        let assistantMessageId = UUID().uuidString

        let userMessage = ChatMessage(
            id: userMessageId,
            sessionId: sessionId,
            role: .user,
            text: text,
            createdAt: now,
            contentBlocks: [.text(text)],
            status: .completed
        )

        try await database.saveMessages([userMessage], for: sessionId)

        let ids = ChatStreamIDs(userMessageId: userMessageId, assistantMessageId: assistantMessageId)
        streamHandler?(.responseStarted(ids))
        streamHandler?(.status(.processing))

        do {
            let context = await buildPromptContext(userInput: text)
            let actions = try await modelEngine.generateResponse(for: text, context: context)
            let currentPlan = await database.activePlan()

            if !actions.reply.isEmpty {
                streamHandler?(.textDelta(actions.reply))
            }

            if let strengthSession = actions.strengthSession {
                streamHandler?(.workoutPreview(makeWorkoutPreview(from: strengthSession)))
            }

            if let runningSession = actions.runningSession {
                streamHandler?(.runningPreview(makeRunningPreview(from: runningSession)))
            }

            if let weeklyPlan = actions.weeklyPlan {
                streamHandler?(.planContentBlock(makeWeeklyPlanContentBlock(from: weeklyPlan, currentPlan: currentPlan)))
                if let todayBlock = makeTodayPlanContentBlock(from: weeklyPlan, currentPlan: currentPlan) {
                    streamHandler?(.planContentBlock(todayBlock))
                }
            }

            streamHandler?(.status(.applying))
            _ = try await database.applyCoachActions(actions, conversationId: sessionId, assistantMessageId: assistantMessageId)
            streamHandler?(.status(.completed))
            streamHandler?(.done)

            return SendMessageServiceResponse(
                userMessageId: userMessageId,
                assistantMessageId: assistantMessageId,
                conversationId: sessionId
            )
        } catch {
            streamHandler?(.status(.failed))
            streamHandler?(.error(error.localizedDescription))
            throw error
        }
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        await database.fetchMessages(conversationId: sessionId)
    }

    func fetchMessages(sessionId: String, start: Date, end: Date) async throws -> [ChatMessage] {
        await database.fetchMessages(conversationId: sessionId, start: start, end: end)
    }

    func subscribeToMessages(
        conversationId: String,
        onInsert: @escaping (ChatMessage) -> Void,
        onUpdate: @escaping (ChatMessage) -> Void
    ) async {
        _ = (conversationId, onInsert, onUpdate)
    }

    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        streamHandler = handler
    }

    func unsubscribe() async {}

    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord {
        _ = messageId
        return workoutRecord
    }

    private func buildPromptContext(userInput: String) async -> OnDevicePromptContext {
        let profile = await database.fetchProfile()
        let todayPlan = await database.todayPlan()
        let activePlan = await database.activePlan()

        var recentWorkoutLines: [String] = []
        let calendar = Calendar.current
        for offset in 0..<3 {
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let sessions = await database.sessionsForDay(date)
            let runs = await database.runningRecordsForDay(date)

            if !sessions.isEmpty {
                let strengthSummary = sessions.map { session in
                    let exercises = session.exercises.map(\.name).joined(separator: ", ")
                    return "\(WorkoutDateFormatter().string(from: session.date)): \(session.label ?? "Strength") [\(exercises)]"
                }
                recentWorkoutLines.append(contentsOf: strengthSummary)
            }

            if !runs.isEmpty {
                let runSummary = runs.map { record in
                    "\(WorkoutDateFormatter().string(from: record.workoutDate)): run \(record.distanceKm)km in \(record.durationMinutes)m"
                }
                recentWorkoutLines.append(contentsOf: runSummary)
            }
        }

        let effectiveLanguage = OnDeviceCoachPromptBuilder.effectiveLanguage(
            profileLanguage: profile.preferences.language
        )

        return OnDevicePromptContext(
            weightUnit: profile.preferences.weightUnit,
            timezoneIdentifier: profile.preferences.timezone,
            language: effectiveLanguage,
            fitnessGoalSummary: profile.fitnessGoalSummary,
            todayPlanSummary: todayPlan.map(Self.describe(planDay:)),
            weeklyPlanSummary: activePlan.map(Self.describe(plan:)),
            recentWorkoutsSummary: recentWorkoutLines,
            userInput: userInput
        )
    }

    private func makeWorkoutPreview(from session: LocalCoachStrengthSession) -> WorkoutRecordBlock {
        WorkoutRecordBlock(
            workoutSessionId: "preview-strength",
            workoutDate: WorkoutDateFormatter().string(from: session.workoutDate),
            title: session.title,
            parseStatus: ParseStatus.processing.rawValue,
            exercises: session.exercises.enumerated().map { exerciseOffset, exercise in
                ContentBlockExercise(
                    exerciseId: "preview-exercise-\(exerciseOffset)",
                    name: exercise.name,
                    orderIndex: exerciseOffset,
                    sets: exercise.sets.enumerated().map { setOffset, set in
                        ContentBlockSet(
                            setId: "preview-set-\(exerciseOffset)-\(setOffset)",
                            setIndex: setOffset + 1,
                            weight: set.weight,
                            weightUnit: set.weightUnit.rawValue,
                            reps: set.reps
                        )
                    }
                )
            }
        )
    }

    private func makeRunningPreview(from running: LocalCoachRunningSession) -> RunningRecordBlock {
        RunningRecordBlock(
            runningWorkoutId: "preview-running",
            workoutDate: WorkoutDateFormatter().string(from: running.workoutDate),
            durationMinutes: running.durationMinutes,
            distanceKm: running.distanceKm,
            source: RunningWorkoutSource.chat.rawValue
        )
    }

    private func makeWeeklyPlanContentBlock(from plan: LocalCoachWeeklyPlan, currentPlan: TrainingPlan?) -> ContentBlock {
        let currentPlan = currentPlan ?? TrainingPlan(
            id: "local-plan",
            weekStartDate: WorkoutDateFormatter().string(from: Date()),
            goalSummary: plan.goalSummary,
            coachSummary: plan.coachSummary,
            days: []
        )

        return .weeklyPlan(
            WeeklyPlanBlock(
                planId: currentPlan.id,
                weekStartDate: currentPlan.weekStartDate,
                goalSummary: plan.goalSummary,
                coachSummary: plan.coachSummary,
                days: buildPlanDayBlocks(from: plan, weekStartDate: currentPlan.weekStartDate)
            )
        )
    }

    private func makeTodayPlanContentBlock(from plan: LocalCoachWeeklyPlan, currentPlan: TrainingPlan?) -> ContentBlock? {
        guard let currentPlan else { return nil }
        let blocks = buildPlanDayBlocks(from: plan, weekStartDate: currentPlan.weekStartDate)
        let todayString = WorkoutDateFormatter().string(from: Date())
        guard let day = blocks.first(where: { $0.planDate == todayString }) else { return nil }
        return .todayPlan(TodayPlanBlock(planId: currentPlan.id, goalSummary: plan.goalSummary, day: day))
    }

    private func buildPlanDayBlocks(from plan: LocalCoachWeeklyPlan, weekStartDate: String) -> [PlanDayBlock] {
        let calendar = Calendar.current
        let startDate = WorkoutDateFormatter().date(from: weekStartDate) ?? calendar.startOfDay(for: Date())

        return plan.days.sorted { $0.dayIndex < $1.dayIndex }.enumerated().map { offset, day in
            let date = calendar.date(byAdding: .day, value: offset, to: startDate) ?? startDate
            return PlanDayBlock(
                planDayId: "preview-plan-day-\(day.dayIndex)",
                planDate: WorkoutDateFormatter().string(from: date),
                dayIndex: day.dayIndex,
                title: day.title,
                focus: day.focus,
                status: day.status,
                exercises: day.exercises.enumerated().map { exerciseOffset, exercise in
                    PlanExerciseBlock(
                        planExerciseId: "preview-plan-exercise-\(day.dayIndex)-\(exerciseOffset)",
                        orderIndex: exerciseOffset,
                        exerciseName: exercise.exerciseName,
                        exerciseLoadType: exercise.exerciseLoadType,
                        progressionMode: exercise.progressionMode,
                        notes: exercise.notes,
                        sets: exercise.sets.enumerated().map { setOffset, set in
                            PlanSetBlock(
                                planSetId: "preview-plan-set-\(day.dayIndex)-\(exerciseOffset)-\(setOffset)",
                                setIndex: setOffset + 1,
                                targetWeight: set.targetWeight,
                                targetWeightUnit: set.targetWeightUnit.rawValue,
                                targetReps: set.targetReps,
                                completedAt: nil,
                                linkedExerciseSetId: nil
                            )
                        }
                    )
                }
            )
        }
    }

    private static func describe(planDay: TrainingPlanDay) -> String {
        let exerciseSummary = planDay.exercises.map { exercise in
            let setSummary = exercise.sets.map { set in
                let weight = set.targetWeight.map { "\($0)\(set.targetWeightUnit.rawValue)" } ?? "bodyweight"
                return "\(set.setIndex)x\(set.targetReps) @ \(weight)"
            }.joined(separator: ", ")
            return "\(exercise.exerciseName): \(setSummary)"
        }.joined(separator: " | ")

        return "\(planDay.title) (\(planDay.planDate)) \(exerciseSummary)"
    }

    private static func describe(plan: TrainingPlan) -> String {
        plan.days.map(describe(planDay:)).joined(separator: "\n")
    }
}

final class MockChatService: ChatServiceProtocol {
    private let local = OnDeviceChatService(database: .shared)

    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        try await local.sendMessage(text, sessionId: sessionId)
    }

    func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        try await local.fetchMessages(sessionId: sessionId)
    }

    func fetchMessages(sessionId: String, start: Date, end: Date) async throws -> [ChatMessage] {
        try await local.fetchMessages(sessionId: sessionId, start: start, end: end)
    }

    func subscribeToMessages(
        conversationId: String,
        onInsert: @escaping (ChatMessage) -> Void,
        onUpdate: @escaping (ChatMessage) -> Void
    ) async {
        await local.subscribeToMessages(conversationId: conversationId, onInsert: onInsert, onUpdate: onUpdate)
    }

    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        local.setStreamEventHandler(handler)
    }

    func unsubscribe() async {
        await local.unsubscribe()
    }

    func confirmWorkoutRecord(messageId: String, workoutRecord: WorkoutRecord) async throws -> WorkoutRecord {
        try await local.confirmWorkoutRecord(messageId: messageId, workoutRecord: workoutRecord)
    }
}

struct OnDevicePromptContext {
    let weightUnit: WeightUnit
    let timezoneIdentifier: String
    let language: AppLanguage
    let fitnessGoalSummary: String?
    let todayPlanSummary: String?
    let weeklyPlanSummary: String?
    let recentWorkoutsSummary: [String]
    let userInput: String
}

struct OnDeviceCoachPromptBuilder {
    static func effectiveLanguage(
        profileLanguage: AppLanguage,
        currentLanguageProvider: () -> AppLanguage = { AppLanguage.current() }
    ) -> AppLanguage {
        _ = profileLanguage
        return currentLanguageProvider()
    }

    static func instructions(for context: OnDevicePromptContext) -> String {
        let localeLine = localeInstruction(for: context.language)
        let responseLanguageLine = responseLanguageInstruction(for: context.language)
        let chineseStrengthExample = """
        Example for Chinese strength logging:
        - Input: "完成一组硬拉 60kg，10个"
        - Output: keep the exercise name as "硬拉", create one completed strength set, set weight to 60, weightUnit to "kg", reps to 10.
        """

        return """
        You are PeakLog, an on-device fitness assistant inside a local-only iOS app.
        \(localeLine)
        \(responseLanguageLine)

        Decide whether the user is:
        1. logging a completed strength workout,
        2. logging a completed running workout,
        3. asking to revise the weekly plan,
        4. updating long-term fitness goals,
        5. or asking a general question that should only receive a reply.

        Rules:
        - Use structured output only.
        - If the user is ambiguous, ask one short clarifying question in reply and keep all action fields empty.
        - Only create workout logs for completed training, not future plans.
        - Only revise the weekly plan when the user explicitly asks to change future training.
        - Keep reply concise and practical.
        - Preserve the exercise identity from the user's message. Do not replace one exercise with another unless the user explicitly corrected the name.
        - If the user writes in Chinese, keep Chinese exercise names in the structured output.
        - If the user provides an explicit numeric weight, do not drop it and do not treat the set as bodyweight.
        - Use nil weight only when the exercise is clearly bodyweight and no external load is provided.
        \(chineseStrengthExample)
        """
    }

    static func prompt(for context: OnDevicePromptContext) -> String {
        """
        User preferences:
        - weight unit: \(context.weightUnit.rawValue)
        - timezone: \(context.timezoneIdentifier)
        - app language: \(context.language.rawValue)

        Fitness goal:
        \(context.fitnessGoalSummary ?? "Not set.")

        Today's plan:
        \(context.todayPlanSummary ?? "No plan available.")

        Weekly plan:
        \(context.weeklyPlanSummary ?? "No weekly plan available.")

        Recent workouts:
        \(context.recentWorkoutsSummary.isEmpty ? "No recent workouts." : context.recentWorkoutsSummary.joined(separator: "\n"))

        User message:
        \(context.userInput)
        """
    }

    private static func localeInstruction(for language: AppLanguage) -> String {
        switch language {
        case .english:
            return ""
        case .simplifiedChinese:
            return "The person's locale is \(language.localeIdentifier)."
        }
    }

    private static func responseLanguageInstruction(for language: AppLanguage) -> String {
        switch language {
        case .english:
            return "You MUST respond in U.S. English."
        case .simplifiedChinese:
            return "You MUST respond in Simplified Chinese."
        }
    }
}

private enum OnDeviceModelError: LocalizedError {
    case unavailable
    case frameworkUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Foundation Models is not available on this device or simulator."
        case .frameworkUnavailable:
            return "Foundation Models framework is unavailable in the current build environment."
        }
    }
}

private final class OnDeviceCoachModelEngine {
    func generateResponse(for userInput: String, context: OnDevicePromptContext) async throws -> LocalCoachActionBundle {
        _ = userInput
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                throw OnDeviceModelError.unavailable
            }

            let session = LanguageModelSession(
                model: model,
                instructions: OnDeviceCoachPromptBuilder.instructions(for: context)
            )

            let prompt = OnDeviceCoachPromptBuilder.prompt(for: context)

            let response = try await session.respond(to: prompt, generating: OnDeviceCoachResponse.self)
            return response.content.toLocalCoachActionBundle()
        }
        #endif

        throw OnDeviceModelError.frameworkUnavailable
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "Structured result for PeakLog's on-device coach.")
private struct OnDeviceCoachResponse {
    let reply: String
    let strengthSession: OnDeviceStrengthSession?
    let runningSession: OnDeviceRunningSession?
    let weeklyPlan: OnDeviceWeeklyPlan?
    let fitnessGoalSummary: String?

    func toLocalCoachActionBundle() -> LocalCoachActionBundle {
        LocalCoachActionBundle(
            reply: reply,
            strengthSession: strengthSession?.toLocalPayload(),
            runningSession: runningSession?.toLocalPayload(),
            weeklyPlan: weeklyPlan?.toLocalPayload(),
            fitnessGoalSummary: fitnessGoalSummary
        )
    }
}

@available(iOS 26.0, *)
@Generable(description: "A completed strength workout that should be logged for today.")
private struct OnDeviceStrengthSession {
    let title: String?
    let exercises: [OnDeviceStrengthExercise]

    func toLocalPayload() -> LocalCoachStrengthSession? {
        let mapped = exercises.compactMap { $0.toLocalPayload() }
        guard !mapped.isEmpty else { return nil }
        return LocalCoachStrengthSession(title: title, workoutDate: Date(), exercises: mapped)
    }
}

@available(iOS 26.0, *)
@Generable(description: "One exercise with sets completed by the user.")
private struct OnDeviceStrengthExercise {
    let name: String
    let sets: [OnDeviceStrengthSet]

    func toLocalPayload() -> LocalCoachStrengthSession.ExercisePayload? {
        let mapped = sets.compactMap { $0.toLocalPayload() }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !mapped.isEmpty else {
            return nil
        }
        return LocalCoachStrengthSession.ExercisePayload(name: name, sets: mapped)
    }
}

@available(iOS 26.0, *)
@Generable(description: "A single completed set. Use nil weight for bodyweight exercises.")
private struct OnDeviceStrengthSet {
    let weight: Double?
    let weightUnit: String
    let reps: Int
    let rpe: Double?

    func toLocalPayload() -> LocalCoachStrengthSession.ExerciseSetPayload? {
        guard reps > 0 else { return nil }
        return LocalCoachStrengthSession.ExerciseSetPayload(
            weight: weight,
            weightUnit: WeightUnit(rawValue: weightUnit) ?? .kg,
            reps: reps,
            rpe: rpe
        )
    }
}

@available(iOS 26.0, *)
@Generable(description: "A completed running workout that should be logged for today.")
private struct OnDeviceRunningSession {
    let durationMinutes: Int
    let distanceKm: Double

    func toLocalPayload() -> LocalCoachRunningSession? {
        guard durationMinutes > 0, distanceKm > 0 else { return nil }
        return LocalCoachRunningSession(workoutDate: Date(), durationMinutes: durationMinutes, distanceKm: distanceKm)
    }
}

@available(iOS 26.0, *)
@Generable(description: "A revised weekly training plan when the user asks to change future training.")
private struct OnDeviceWeeklyPlan {
    let goalSummary: String?
    let coachSummary: String
    let days: [OnDevicePlanDay]

    func toLocalPayload() -> LocalCoachWeeklyPlan? {
        let mapped = days.compactMap { $0.toLocalPayload() }
        guard !coachSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !mapped.isEmpty else {
            return nil
        }
        return LocalCoachWeeklyPlan(goalSummary: goalSummary, coachSummary: coachSummary, days: mapped)
    }
}

@available(iOS 26.0, *)
@Generable(description: "One day in the weekly plan.")
private struct OnDevicePlanDay {
    let dayIndex: Int
    let title: String
    let focus: String?
    let status: String
    let exercises: [OnDevicePlanExercise]

    func toLocalPayload() -> LocalCoachPlanDay? {
        let mapped = exercises.compactMap { $0.toLocalPayload() }
        guard (1...7).contains(dayIndex), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return LocalCoachPlanDay(dayIndex: dayIndex, title: title, focus: focus, status: status, exercises: mapped)
    }
}

@available(iOS 26.0, *)
@Generable(description: "One exercise prescribed in a plan day.")
private struct OnDevicePlanExercise {
    let exerciseName: String
    let exerciseLoadType: String
    let progressionMode: String
    let notes: String?
    let sets: [OnDevicePlanSet]

    func toLocalPayload() -> LocalCoachPlanExercise? {
        let mapped = sets.compactMap { $0.toLocalPayload() }
        guard !exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !mapped.isEmpty else {
            return nil
        }
        return LocalCoachPlanExercise(
            exerciseName: exerciseName,
            exerciseLoadType: ExerciseLoadType(rawValue: exerciseLoadType) ?? .unknown,
            progressionMode: progressionMode,
            notes: notes,
            sets: mapped
        )
    }
}

@available(iOS 26.0, *)
@Generable(description: "One planned set.")
private struct OnDevicePlanSet {
    let targetWeight: Double?
    let targetWeightUnit: String
    let targetReps: Int

    func toLocalPayload() -> LocalCoachPlanSet? {
        guard targetReps > 0 else { return nil }
        return LocalCoachPlanSet(
            targetWeight: targetWeight,
            targetWeightUnit: WeightUnit(rawValue: targetWeightUnit) ?? .kg,
            targetReps: targetReps
        )
    }
}
#endif
