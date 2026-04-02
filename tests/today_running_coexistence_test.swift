import Foundation
import CoreGraphics

@main
struct TodayRunningCoexistenceTestRunner {
    static func main() async {
        await loadsPlanStrengthAndRunningTogether()
        print("today_running_coexistence_test passed")
    }

    @MainActor
    private static func loadsPlanStrengthAndRunningTogether() async {
        let formatter = WorkoutDateFormatter()
        let today = formatter.date(from: "2026-04-01") ?? Date()

        let trainingPlanService = TodayRunningCoexistenceTrainingPlanService()
        let workoutService = TodayRunningCoexistenceWorkoutService(today: today)
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: trainingPlanService,
            workoutService: workoutService,
            chatService: IdleChatService(),
            conversationService: MockConversationService(conversationId: "conversation-1"),
            speechRecognitionService: TestSpeechRecognitionService()
        )

        await viewModel.refresh()

        precondition(viewModel.todayPlan?.title == "Deep Leg Day", "Expected the existing training plan to stay visible")
        precondition(viewModel.todayRecord?.exercises.count == 1, "Expected the existing strength record to remain loaded")
        precondition(viewModel.runningRecords.count == 1, "Expected running records to load alongside the existing strength content")
        precondition(viewModel.runningRecords.first?.distanceKm == 4.2, "Expected the running record payload to remain intact")
    }
}

private struct TodayRunningCoexistenceTrainingPlanService: TrainingPlanServiceProtocol {
    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        TrainingPlanDay(
            id: "day-1",
            planDate: "2026-04-01",
            dayIndex: 3,
            title: "Deep Leg Day",
            focus: "下肢力量",
            status: "planned",
            exercises: [
                TrainingPlanExercise(
                    id: "plan-exercise-1",
                    orderIndex: 0,
                    exerciseName: "杠铃深蹲",
                    exerciseLoadType: .weighted,
                    progressionMode: "weight_first",
                    notes: nil,
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(
                            id: "plan-set-1",
                            setIndex: 1,
                            targetWeight: 40,
                            targetWeightUnit: .kg,
                            targetReps: 8,
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
            id: "\(planExerciseId)-new-set",
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

private struct TodayRunningCoexistenceWorkoutService: WorkoutServiceProtocol {
    let today: Date

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
        ExerciseSet(id: setId, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func addSet(
        sessionId: String,
        exerciseId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) async throws -> ExerciseSet {
        ExerciseSet(id: UUID().uuidString, setIndex: 2, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}
    func deleteExercise(sessionId: String, exerciseId: String) async throws {}

    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: 60, weightUnit: .kg, reps: 6, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [today] }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        [
            WorkoutSession(
                id: "session-1",
                userId: "user-1",
                date: date,
                durationMinutes: 48,
                label: "Leg Strength",
                exercises: [
                    Exercise(
                        id: "exercise-1",
                        name: "Barbell Squat",
                        sets: [
                            ExerciseSet(id: "set-1", setIndex: 1, weight: 100, weightUnit: .kg, reps: 5, rpe: 8)
                        ]
                    )
                ],
                createdAt: date,
                updatedAt: date
            )
        ]
    }

    func activeRunningDaysInMonth(year: Int, month: Int) async throws -> [Date] { [today] }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] {
        [
            RunningWorkoutRecord(
                id: "run-1",
                userId: "user-1",
                workoutDate: date,
                durationMinutes: 26,
                distanceKm: 4.2,
                source: .manual,
                createdAt: date,
                updatedAt: date
            )
        ]
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord {
        RunningWorkoutRecord(
            id: "run-created",
            userId: "user-1",
            workoutDate: workoutDate,
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            source: source,
            createdAt: workoutDate,
            updatedAt: workoutDate
        )
    }
}

private struct IdleChatService: ChatServiceProtocol {
    func sendMessage(_ text: String, sessionId: String) async throws -> SendMessageServiceResponse {
        _ = (text, sessionId)
        return SendMessageServiceResponse(
            userMessageId: "user-message",
            assistantMessageId: "assistant-message",
            conversationId: sessionId
        )
    }

    func setStreamEventHandler(_ handler: ChatServiceStreamHandler?) {
        _ = handler
    }
}
