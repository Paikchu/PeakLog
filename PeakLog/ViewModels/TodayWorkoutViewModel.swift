import Foundation
import Combine
import CoreGraphics

@MainActor
final class TodayWorkoutViewModel: ObservableObject {
    @Published var todayPlan: TrainingPlanDay?
    @Published var todayRecord: WorkoutRecord?
    @Published var quickActions: [AIWorkoutQuickAction] = []
    @Published var inputText = ""
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var latestAssistantReply: String?
    @Published private(set) var voiceInputState: VoiceInputState = .idle

    private let trainingPlanService: TrainingPlanServiceProtocol
    private let workoutService: WorkoutServiceProtocol
    private let aiActionService: WorkoutAIActionServiceProtocol
    private let speechRecognitionService: SpeechRecognitionServicing
    private let workoutDateFormatter = WorkoutDateFormatter()

    private var inputTextBeforeVoiceRecording = ""

    init(
        trainingPlanService: TrainingPlanServiceProtocol,
        workoutService: WorkoutServiceProtocol,
        aiActionService: WorkoutAIActionServiceProtocol,
        speechRecognitionService: SpeechRecognitionServicing
    ) {
        self.trainingPlanService = trainingPlanService
        self.workoutService = workoutService
        self.aiActionService = aiActionService
        self.speechRecognitionService = speechRecognitionService
    }

    #if !TESTING
    convenience init() {
        self.init(
            trainingPlanService: SupabaseTrainingPlanService(),
            workoutService: SupabaseWorkoutService(),
            aiActionService: SupabaseWorkoutAIActionService(),
            speechRecognitionService: SpeechRecognitionService()
        )
    }
    #endif

    func onAppear() async {
        guard todayPlan == nil, todayRecord == nil else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let plan = trainingPlanService.fetchTodayPlan()
            async let sessions = workoutService.sessionsForDay(Date())
            let (loadedPlan, loadedSessions) = try await (plan, sessions)
            todayPlan = loadedPlan
            todayRecord = mergeSessionsIntoRecord(loadedSessions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendAction() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, voiceInputState == .idle else { return }

        errorMessage = nil
        isSending = true
        inputText = ""

        do {
            let response = try await aiActionService.submitAction(
                text: text,
                targetDate: workoutDateFormatter.string(from: Date())
            )
            latestAssistantReply = response.reply
            quickActions = response.quickActions
            applyExerciseInsights(response.exerciseInsights)
            if response.requiresTodayRefresh {
                await refresh()
            }
            isSending = false
        } catch {
            errorMessage = error.localizedDescription
            inputText = text
            isSending = false
        }
    }

    func completePlannedSet(planSetId: String, rpe: Double? = nil) async {
        guard let set = findPlanSet(planSetId: planSetId) else { return }
        updatePlanSetInPlace(planSetId: planSetId) { current in
            current.completedAt = Date()
        }

        do {
            let updated = try await trainingPlanService.completePlannedSet(
                planSetId: planSetId,
                actualWeight: set.targetWeight,
                actualWeightUnit: set.targetWeightUnit,
                actualReps: set.targetReps
            )
            updatePlanSetInPlace(planSetId: planSetId) { current in
                current.completedAt = updated.completedAt
                current.linkedExerciseSetId = updated.linkedExerciseSetId
            }
            if let linkedSetId = updated.linkedExerciseSetId, let rpe {
                _ = try await workoutService.updateSetRPE(setId: linkedSetId, rpe: rpe)
            }
            await refreshTodayRecordOnly()
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) async {
        updatePlanSetInPlace(planSetId: planSetId) { current in
            current.targetWeight = targetWeight
            current.targetWeightUnit = targetWeightUnit
            current.targetReps = targetReps
        }

        do {
            let updated = try await trainingPlanService.updatePlannedSet(
                planSetId: planSetId,
                targetWeight: targetWeight,
                targetWeightUnit: targetWeightUnit,
                targetReps: targetReps
            )
            updatePlanSetInPlace(planSetId: planSetId) { current in
                current.targetWeight = updated.targetWeight
                current.targetWeightUnit = updated.targetWeightUnit
                current.targetReps = updated.targetReps
                current.completedAt = updated.completedAt
                current.linkedExerciseSetId = updated.linkedExerciseSetId
            }
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    func addPlannedSet(planExerciseId: String) async {
        guard let exercise = findPlanExercise(planExerciseId: planExerciseId) else { return }
        let template = exercise.sets.last ?? TrainingPlanSet(
            id: "template",
            setIndex: exercise.sets.count + 1,
            targetWeight: nil,
            targetWeightUnit: .kg,
            targetReps: 10,
            completedAt: nil,
            linkedExerciseSetId: nil
        )

        do {
            let inserted = try await trainingPlanService.addPlannedSet(
                planExerciseId: planExerciseId,
                targetWeight: template.targetWeight,
                targetWeightUnit: template.targetWeightUnit,
                targetReps: template.targetReps
            )
            appendPlannedSet(inserted, to: planExerciseId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteLastPlannedSet(planExerciseId: String) async {
        guard let lastSetId = findPlanExercise(planExerciseId: planExerciseId)?.sets.last?.id else { return }
        removeLastPlannedSet(from: planExerciseId)

        do {
            try await trainingPlanService.deletePlannedSet(planSetId: lastSetId)
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    func updateLoggedSet(exerciseId: String, updatedSet: ExerciseSet) async {
        updateLoggedSetInPlace(exerciseId: exerciseId, setId: updatedSet.id) { current in
            current.weight = updatedSet.weight
            current.weightUnit = updatedSet.weightUnit
            current.reps = updatedSet.reps
        }

        do {
            _ = try await workoutService.updateSet(
                sessionId: todayRecord?.id ?? "",
                exerciseId: exerciseId,
                setId: updatedSet.id,
                weight: updatedSet.weight,
                weightUnit: updatedSet.weightUnit,
                reps: updatedSet.reps
            )
        } catch {
            errorMessage = error.localizedDescription
            await refreshTodayRecordOnly()
        }
    }

    func addLoggedSet(exerciseId: String) async {
        guard let template = todayRecord?.exercises.first(where: { $0.id == exerciseId })?.sets.last else { return }
        do {
            let inserted = try await workoutService.addSet(
                sessionId: todayRecord?.id ?? "",
                exerciseId: exerciseId,
                weight: template.weight,
                weightUnit: template.weightUnit,
                reps: template.reps
            )
            appendLoggedSet(inserted, to: exerciseId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteLastLoggedSet(exerciseId: String) async {
        guard let lastSetId = todayRecord?.exercises.first(where: { $0.id == exerciseId })?.sets.last?.id else { return }
        removeLastLoggedSet(from: exerciseId)

        do {
            try await workoutService.deleteSet(
                sessionId: todayRecord?.id ?? "",
                exerciseId: exerciseId,
                setId: lastSetId
            )
        } catch {
            errorMessage = error.localizedDescription
            await refreshTodayRecordOnly()
        }
    }

    func toggleVoiceInput() async {
        guard !isSending else { return }

        switch voiceInputState {
        case .idle:
            await startVoiceRecording()
        case .recording:
            await stopVoiceRecordingAndTranscribe()
        case .transcribing:
            break
        }
    }

    private func startVoiceRecording() async {
        errorMessage = nil
        inputTextBeforeVoiceRecording = inputText

        do {
            try await speechRecognitionService.startRecognition(
                onLevelUpdate: { _ in },
                onTranscriptUpdate: { [weak self] transcript in
                    Task { @MainActor in
                        self?.inputText = transcript
                    }
                }
            )
            voiceInputState = .recording
        } catch {
            handleVoiceFailure(error)
        }
    }

    private func stopVoiceRecordingAndTranscribe() async {
        voiceInputState = .transcribing

        do {
            let transcript = try await speechRecognitionService.stopRecognition()
            inputText = transcript
            inputTextBeforeVoiceRecording = ""
            voiceInputState = .idle
        } catch {
            handleVoiceFailure(error)
        }
    }

    private func handleVoiceFailure(_ error: Error) {
        inputText = inputTextBeforeVoiceRecording
        inputTextBeforeVoiceRecording = ""
        voiceInputState = .idle
        errorMessage = error.localizedDescription
    }

    private func refreshTodayRecordOnly() async {
        do {
            let sessions = try await workoutService.sessionsForDay(Date())
            todayRecord = mergeSessionsIntoRecord(sessions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeSessionsIntoRecord(_ sessions: [WorkoutSession]) -> WorkoutRecord? {
        let exercises = sessions.flatMap(\.exercises)
        guard !exercises.isEmpty else { return nil }
        return WorkoutRecord(id: sessions.first?.id ?? "today-record", exercises: exercises)
    }

    private func applyExerciseInsights(_ insights: [AIWorkoutExerciseInsight]) {
        guard var plan = todayPlan, !insights.isEmpty else { return }
        let insightsByName = Dictionary(uniqueKeysWithValues: insights.map {
            ($0.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0)
        })

        for index in plan.exercises.indices {
            let key = plan.exercises[index].exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let insight = insightsByName[key] else { continue }
            plan.exercises[index].previousPerformanceSummary = insight.previousPerformanceSummary
            plan.exercises[index].aiSuggestion = insight.suggestion
        }

        todayPlan = plan
    }

    private func findPlanExercise(planExerciseId: String) -> TrainingPlanExercise? {
        todayPlan?.exercises.first(where: { $0.id == planExerciseId })
    }

    private func findPlanSet(planSetId: String) -> TrainingPlanSet? {
        todayPlan?.exercises
            .flatMap(\.sets)
            .first(where: { $0.id == planSetId })
    }

    private func updatePlanSetInPlace(planSetId: String, update: (inout TrainingPlanSet) -> Void) {
        guard var plan = todayPlan else { return }
        for exerciseIndex in plan.exercises.indices {
            guard let setIndex = plan.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == planSetId }) else { continue }
            update(&plan.exercises[exerciseIndex].sets[setIndex])
            todayPlan = plan
            return
        }
    }

    private func appendPlannedSet(_ set: TrainingPlanSet, to planExerciseId: String) {
        guard var plan = todayPlan else { return }
        for exerciseIndex in plan.exercises.indices where plan.exercises[exerciseIndex].id == planExerciseId {
            plan.exercises[exerciseIndex].sets.append(set)
            plan.exercises[exerciseIndex].sets.sort { $0.setIndex < $1.setIndex }
            todayPlan = plan
            return
        }
    }

    private func removeLastPlannedSet(from planExerciseId: String) {
        guard var plan = todayPlan else { return }
        for exerciseIndex in plan.exercises.indices where plan.exercises[exerciseIndex].id == planExerciseId {
            guard plan.exercises[exerciseIndex].sets.count > 1 else { return }
            _ = plan.exercises[exerciseIndex].sets.popLast()
            todayPlan = plan
            return
        }
    }

    private func updateLoggedSetInPlace(exerciseId: String, setId: String, update: (inout ExerciseSet) -> Void) {
        guard var record = todayRecord else { return }
        for exerciseIndex in record.exercises.indices where record.exercises[exerciseIndex].id == exerciseId {
            guard let setIndex = record.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) else { continue }
            update(&record.exercises[exerciseIndex].sets[setIndex])
            todayRecord = record
            return
        }
    }

    private func appendLoggedSet(_ set: ExerciseSet, to exerciseId: String) {
        guard var record = todayRecord else { return }
        for exerciseIndex in record.exercises.indices where record.exercises[exerciseIndex].id == exerciseId {
            record.exercises[exerciseIndex].sets.append(set)
            record.exercises[exerciseIndex].sets.sort { $0.setIndex < $1.setIndex }
            todayRecord = record
            return
        }
    }

    private func removeLastLoggedSet(from exerciseId: String) {
        guard var record = todayRecord else { return }
        for exerciseIndex in record.exercises.indices where record.exercises[exerciseIndex].id == exerciseId {
            guard record.exercises[exerciseIndex].sets.count > 1 else { return }
            _ = record.exercises[exerciseIndex].sets.popLast()
            todayRecord = record
            return
        }
    }
}
