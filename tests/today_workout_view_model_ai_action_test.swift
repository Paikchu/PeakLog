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

struct WorkoutAIActionResponse {
    let status: String
    let reply: String
    let requiresTodayRefresh: Bool
    let quickActions: [AIWorkoutQuickAction]
    let exerciseInsights: [AIWorkoutExerciseInsight]
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

protocol WorkoutAIActionServiceProtocol {
    func submitAction(text: String, targetDate: String?) async throws -> WorkoutAIActionResponse
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
        await appliesStructuredAIActionResponseToTodayPageState()
        print("today_workout_view_model_ai_action_test passed")
    }

    @MainActor
    private static func appliesStructuredAIActionResponseToTodayPageState() async {
        let trainingPlanService = TestTrainingPlanService()
        let workoutService = TestWorkoutService()
        let aiActionService = TestWorkoutAIActionService(
            response: WorkoutAIActionResponse(
                status: "completed",
                reply: "卧推今天状态不错，建议后两组加 2.5kg。",
                requiresTodayRefresh: false,
                quickActions: [
                    AIWorkoutQuickAction(
                        id: "add-load",
                        title: "后两组加 2.5kg",
                        prompt: "把卧推后两组加 2.5kg"
                    )
                ],
                exerciseInsights: [
                    AIWorkoutExerciseInsight(
                        exerciseName: "Bench Press",
                        previousPerformanceSummary: "上次：70kg × 5",
                        suggestion: "如果本组 RPE ≤ 8，可以加 2.5kg。"
                    )
                ]
            )
        )

        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: trainingPlanService,
            workoutService: workoutService,
            aiActionService: aiActionService,
            speechRecognitionService: TestSpeechRecognitionService()
        )

        await viewModel.refresh()
        viewModel.inputText = "卧推今天感觉偏轻"
        await viewModel.sendAction()

        precondition(viewModel.latestAssistantReply == "卧推今天状态不错，建议后两组加 2.5kg。", "Expected assistant reply to update")
        precondition(viewModel.quickActions.count == 1, "Expected quick actions to be exposed on the page")
        precondition(viewModel.quickActions.first?.title == "后两组加 2.5kg", "Expected quick action title to decode")

        let exercise = viewModel.todayPlan?.exercises.first
        precondition(exercise?.previousPerformanceSummary == "上次：70kg × 5", "Expected exercise insight to update previous performance summary")
        precondition(exercise?.aiSuggestion == "如果本组 RPE ≤ 8，可以加 2.5kg。", "Expected exercise insight to update AI suggestion")
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

private struct TestWorkoutAIActionService: WorkoutAIActionServiceProtocol {
    let response: WorkoutAIActionResponse

    func submitAction(text: String, targetDate: String?) async throws -> WorkoutAIActionResponse {
        _ = (text, targetDate)
        return response
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
