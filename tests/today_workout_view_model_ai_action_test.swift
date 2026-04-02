import Foundation
import CoreGraphics

struct AIWorkoutQuickAction: Equatable, Identifiable {
    let id: String
    let title: String
    let prompt: String
}

struct AIWorkoutExerciseInsight: Equatable {
    let exerciseName: String
    let previousPerformanceSummary: String?
    let suggestion: String?
}

enum VoiceInputState: Equatable {
    case idle
    case recording
    case transcribing
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

enum ChatServiceStreamStatus: String, Equatable {
    case processing
    case applying
    case completed
    case failed
}

enum ChatServiceStreamEvent: Equatable {
    case responseStarted(ChatStreamIDs)
    case status(ChatServiceStreamStatus)
    case textDelta(String)
    case workoutPreview(WorkoutRecordBlock)
    case planContentBlock(ContentBlock)
    case error(String)
    case done
}

typealias ChatServiceStreamHandler = @Sendable (ChatServiceStreamEvent) -> Void

protocol SpeechRecognitionServicing {
    func startRecognition(
        onLevelUpdate: @escaping (CGFloat) -> Void,
        onTranscriptUpdate: @escaping (String) -> Void
    ) async throws
    func stopRecognition() async throws -> String
}

protocol ChatServiceProtocol {
    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse
    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?)
}

protocol ConversationServiceProtocol {
    func fetchOrCreateDefaultConversationId() async throws -> String
}

struct MockConversationService: ConversationServiceProtocol {
    let conversationId: String

    func fetchOrCreateDefaultConversationId() async throws -> String {
        conversationId
    }
}

protocol TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan?
    func fetchTodayPlan() async throws -> TrainingPlanDay?
    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet
    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet
    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet
    func deletePlannedSet(planSetId: String) async throws
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
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date]
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession]
}

@main
struct TodayWorkoutViewModelAIActionTestRunner {
    static func main() async {
        await appliesStreamingPlanAdjustmentResponseToTodayPageState()
        print("today_workout_view_model_ai_action_test passed")
    }

    @MainActor
    private static func appliesStreamingPlanAdjustmentResponseToTodayPageState() async {
        let trainingPlanService = TestTrainingPlanService()
        let workoutService = TestWorkoutService()
        let chatService = TestChatService(
            events: [
                .status(.processing),
                .textDelta("好的，我正在按你的要求重排本周计划。"),
                .status(.applying),
                .planContentBlock(
                    .todayPlan(
                        TodayPlanBlock(
                            planId: "plan-1",
                            goalSummary: "增肌",
                            day: PlanDayBlock(
                                planDayId: "day-1",
                                planDate: "2026-03-30",
                                dayIndex: 1,
                                title: "Chest + Biceps",
                                focus: "胸和二头",
                                status: "planned",
                                exercises: [
                                    PlanExerciseBlock(
                                        planExerciseId: "exercise-1",
                                        orderIndex: 0,
                                        exerciseName: "Bench Press",
                                        exerciseLoadType: .weighted,
                                        progressionMode: "weight_first",
                                        notes: nil,
                                        sets: [
                                            PlanSetBlock(
                                                planSetId: "set-1",
                                                setIndex: 1,
                                                targetWeight: 72.5,
                                                targetWeightUnit: "kg",
                                                targetReps: 8,
                                                completedAt: nil,
                                                linkedExerciseSetId: nil
                                            )
                                        ]
                                    )
                                ]
                            )
                        )
                    )
                ),
                .planContentBlock(
                    .planAdjustmentSummary(
                        PlanAdjustmentSummaryBlock(summaryText: "已改成每周 6 天训练，周一胸 + 二头。")
                    )
                ),
                .status(.completed),
                .done,
            ]
        )

        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: trainingPlanService,
            workoutService: workoutService,
            chatService: chatService,
            conversationService: MockConversationService(conversationId: "conversation-1"),
            speechRecognitionService: TestSpeechRecognitionService()
        )

        await viewModel.refresh()
        viewModel.inputText = "帮我把周一改成胸和二头"
        await viewModel.sendAction()

        precondition(viewModel.isOverlayVisible, "Expected floating overlay to remain visible after completion")
        precondition(viewModel.overlayPhase == .completed, "Expected overlay to enter completed state")
        precondition(viewModel.streamingReply == "好的，我正在按你的要求重排本周计划。", "Expected streamed reply to accumulate text deltas")
        precondition(viewModel.didPersistPlan, "Expected streamed plan content to mark the plan as persisted")
        precondition(viewModel.todayPlan?.title == "Chest + Biceps", "Expected today's plan to update from streamed today_plan block")
        precondition(viewModel.overlayContentBlocks.count == 2, "Expected plan blocks to be retained for overlay rendering")
    }
}

private struct TestTrainingPlanService: TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        TrainingPlanDay(
            id: "day-1",
            planDate: "2026-03-30",
            dayIndex: 1,
            title: "Push Strength",
            focus: "胸肩三头",
            status: "planned",
            exercises: [
                TrainingPlanExercise(
                    id: "exercise-1",
                    orderIndex: 0,
                    exerciseName: "Bench Press",
                    exerciseLoadType: .weighted,
                    progressionMode: "weight_first",
                    notes: nil,
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(
                            id: "set-1",
                            setIndex: 1,
                            targetWeight: 70,
                            targetWeightUnit: .kg,
                            targetReps: 5,
                            completedAt: nil,
                            linkedExerciseSetId: nil
                        )
                    ]
                )
            ]
        )
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: planSetId,
            setIndex: 1,
            targetWeight: actualWeight,
            targetWeightUnit: actualWeightUnit,
            targetReps: actualReps,
            completedAt: Date(),
            linkedExerciseSetId: "exercise-set-1"
        )
    }

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: planSetId,
            setIndex: 1,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async throws -> TrainingPlanSet {
        TrainingPlanSet(
            id: "set-new",
            setIndex: 2,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}
}

private struct TestWorkoutService: WorkoutServiceProtocol {
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
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps, rpe: nil)
    }

    func addSet(
        sessionId: String,
        exerciseId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet {
        ExerciseSet(id: "set-added", setIndex: 2, weight: weight, weightUnit: weightUnit, reps: reps, rpe: nil)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}
    func deleteExercise(sessionId: String, exerciseId: String) async throws {}
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: 70, weightUnit: .kg, reps: 5, rpe: rpe)
    }
    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }
    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] { [] }
}

private final class TestChatService: ChatServiceProtocol {
    let events: [ChatServiceStreamEvent]
    var handler: ChatServiceStreamHandler?

    init(events: [ChatServiceStreamEvent]) {
        self.events = events
    }

    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        _ = (text, sessionId)
        handler?(.responseStarted(ChatStreamIDs(userMessageId: "user-1", assistantMessageId: "assistant-1")))
        for event in events {
            handler?(event)
        }
        return SendMessageServiceResponse(
            userMessageId: "user-1",
            assistantMessageId: "assistant-1",
            conversationId: "conversation-1"
        )
    }

    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        self.handler = handler
    }
}

private struct TestSpeechRecognitionService: SpeechRecognitionServicing {
    func startRecognition(
        onLevelUpdate: @escaping (CGFloat) -> Void,
        onTranscriptUpdate: @escaping (String) -> Void
    ) async throws {
        _ = (onLevelUpdate, onTranscriptUpdate)
    }

    func stopRecognition() async throws -> String { "" }
}
