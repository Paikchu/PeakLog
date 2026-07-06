import Foundation
import Combine
import CoreGraphics

struct PlanLiveWorkoutSet: Identifiable, Equatable {
    let id: String
    let setIndex: Int
    let targetWeight: Double?
    let targetWeightUnit: WeightUnit
    let targetReps: Int
    let isAlreadyCompleted: Bool
}

struct PlanLiveWorkoutExercise: Identifiable, Equatable {
    let id: String
    let name: String
    let loadType: ExerciseLoadType
    let sets: [PlanLiveWorkoutSet]
}

struct PlanLiveWorkoutSession: Identifiable, Equatable {
    let id: String
    let title: String
    let focus: String?
    var exercises: [PlanLiveWorkoutExercise]
    var currentExerciseIndex: Int
    var currentSetIndex: Int
    var completedSetIds: Set<String>

    var currentExercise: PlanLiveWorkoutExercise? {
        guard exercises.indices.contains(currentExerciseIndex) else { return nil }
        return exercises[currentExerciseIndex]
    }

    var currentSet: PlanLiveWorkoutSet? {
        guard let currentExercise, currentExercise.sets.indices.contains(currentSetIndex) else { return nil }
        return currentExercise.sets[currentSetIndex]
    }

    var completedSetsCount: Int {
        completedSetIds.count
    }

    var totalSetsCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }

    var progress: Double {
        guard totalSetsCount > 0 else { return 0 }
        return Double(completedSetsCount) / Double(totalSetsCount)
    }

    var isComplete: Bool {
        completedSetsCount >= totalSetsCount
    }
}

@MainActor
final class TodayWorkoutViewModel: ObservableObject {
    @Published var runningRecords: [RunningWorkoutRecord] = []
    @Published var todayPlan: TrainingPlanDay?
    @Published var todayRecord: WorkoutRecord?
    @Published var activeLiveWorkout: PlanLiveWorkoutSession?
    @Published var quickActions: [AIWorkoutQuickAction] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let trainingPlanService: TrainingPlanServiceProtocol
    private let workoutService: WorkoutServiceProtocol
    private let liveActivityManager: PlanLiveActivityManaging

    private var liveActivityObservationTask: Task<Void, Never>?

    init(
        trainingPlanService: TrainingPlanServiceProtocol,
        workoutService: WorkoutServiceProtocol,
        liveActivityManager: PlanLiveActivityManaging = NoOpPlanLiveActivityManager()
    ) {
        self.trainingPlanService = trainingPlanService
        self.workoutService = workoutService
        self.liveActivityManager = liveActivityManager
    }

    #if !TESTING
    convenience init() {
        self.init(
            trainingPlanService: AppServices.trainingPlanService,
            workoutService: AppServices.workoutService,
            liveActivityManager: PlanLiveActivityManagerFactory.make()
        )
    }
    #endif

    func onAppear() async {
        guard todayPlan == nil, todayRecord == nil, runningRecords.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let plan = trainingPlanService.fetchTodayPlan()
            async let sessions = workoutService.sessionsForDay(Date())
            async let records = workoutService.runningRecordsForDay(Date())
            let (loadedPlan, loadedSessions, loadedRecords) = try await (plan, sessions, records)
            runningRecords = loadedRecords
            todayPlan = loadedPlan
            todayRecord = mergeSessionsIntoRecord(loadedSessions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startPlanLiveWorkout() {
        guard let plan = todayPlan else { return }
        let exercises = plan.exercises
            .filter { !$0.sets.isEmpty }
            .map { exercise in
                PlanLiveWorkoutExercise(
                    id: exercise.id,
                    name: exercise.exerciseName,
                    loadType: exercise.exerciseLoadType,
                    sets: exercise.sets.map { set in
                        PlanLiveWorkoutSet(
                            id: set.id,
                            setIndex: set.setIndex,
                            targetWeight: set.targetWeight,
                            targetWeightUnit: set.targetWeightUnit,
                            targetReps: set.targetReps,
                            isAlreadyCompleted: set.isCompleted
                        )
                    }
                )
            }

        guard !exercises.isEmpty else { return }
        var session = PlanLiveWorkoutSession(
            id: UUID().uuidString,
            title: plan.title,
            focus: plan.focus,
            exercises: exercises,
            currentExerciseIndex: 0,
            currentSetIndex: 0,
            completedSetIds: Set(exercises.flatMap(\.sets).filter(\.isAlreadyCompleted).map(\.id))
        )
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        Task { await liveActivityManager.start(session: session) }
        observeLiveActivityCompletions(sessionId: session.id)
    }

    private func observeLiveActivityCompletions(sessionId: String) {
        liveActivityObservationTask?.cancel()
        liveActivityObservationTask = Task { [weak self] in
            guard let self else { return }
            for await completedSetIds in self.liveActivityManager.completedSetIdUpdates(sessionId: sessionId) {
                self.mergeLiveActivityCompletions(completedSetIds, sessionId: sessionId)
            }
        }
    }

    private func mergeLiveActivityCompletions(_ completedSetIds: Set<String>, sessionId: String) {
        guard var session = activeLiveWorkout, session.id == sessionId else { return }
        guard !completedSetIds.isSubset(of: session.completedSetIds) else { return }

        session.completedSetIds.formUnion(completedSetIds)
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
    }

    func completeCurrentLiveSet() {
        guard var session = activeLiveWorkout, let set = session.currentSet else { return }
        session.completedSetIds.insert(set.id)
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        Task { await liveActivityManager.update(session: session) }
    }

    func toggleLiveSet(setId: String) {
        guard var session = activeLiveWorkout else { return }
        if session.completedSetIds.contains(setId) {
            session.completedSetIds.remove(setId)
        } else {
            session.completedSetIds.insert(setId)
        }
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        Task { await liveActivityManager.update(session: session) }
    }

    func cancelPlanLiveWorkout() {
        liveActivityObservationTask?.cancel()
        liveActivityObservationTask = nil
        activeLiveWorkout = nil
        Task { await liveActivityManager.end() }
    }

    func syncLiveActivityCompletions() {
        guard var session = activeLiveWorkout else { return }
        let completedSetIds = liveActivityManager.consumeCompletedSetIds(sessionId: session.id)
        guard !completedSetIds.isEmpty else { return }

        session.completedSetIds.formUnion(completedSetIds)
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
    }

    func confirmPlanLiveWorkout() async {
        syncLiveActivityCompletions()
        guard let session = activeLiveWorkout else { return }
        let pendingSets = session.exercises
            .flatMap { exercise in
                exercise.sets.map { (exercise, $0) }
            }
            .filter {
                session.completedSetIds.contains($0.1.id)
                    && !$0.1.isAlreadyCompleted
                    && !isPlanSetCompletedInTodayPlan($0.1.id)
            }

        do {
            for (_, set) in pendingSets {
                let updated = try await trainingPlanService.completePlannedSet(
                    planSetId: set.id,
                    actualWeight: set.targetWeight,
                    actualWeightUnit: set.targetWeightUnit,
                    actualReps: set.targetReps
                )
                updatePlanSetInPlace(planSetId: set.id) { current in
                    current.completedAt = updated.completedAt
                    current.linkedExerciseSetId = updated.linkedExerciseSetId
                }
            }

            todayRecord = optimisticWorkoutRecord(from: session)
            liveActivityObservationTask?.cancel()
            liveActivityObservationTask = nil
            activeLiveWorkout = nil
            await liveActivityManager.end()
            await refreshTodayRecordOnly()
            if todayRecord == nil {
                todayRecord = optimisticWorkoutRecord(from: session)
            }
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
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
            markLiveSetCompleted(planSetId: planSetId)
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

    func addPlanExercises(_ drafts: [PlanExerciseDraft]) async {
        guard !drafts.isEmpty else { return }
        do {
            let updatedDay = try await trainingPlanService.addPlannedExercises(drafts)
            todayPlan = updatedDay
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

    private func refreshTodayRecordOnly() async {
        do {
            async let sessions = workoutService.sessionsForDay(Date())
            async let records = workoutService.runningRecordsForDay(Date())
            let (loadedSessions, loadedRecords) = try await (sessions, records)
            todayRecord = mergeSessionsIntoRecord(loadedSessions)
            runningRecords = loadedRecords
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addRunningRecord(durationMinutes: Int, distanceKm: Double) async {
        do {
            let record = try await workoutService.createRunningRecord(
                workoutDate: Date(),
                durationMinutes: durationMinutes,
                distanceKm: distanceKm,
                source: .manual
            )
            runningRecords.append(record)
            runningRecords.sort { $0.createdAt < $1.createdAt }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addDailyRecord(_ draft: DailyRecordDraft) async {
        switch draft {
        case .strength(let strengthDraft):
            await addStrengthRecord(strengthDraft)
        case .cardio(let durationMinutes, let distanceKm):
            await addRunningRecord(durationMinutes: durationMinutes, distanceKm: distanceKm)
        }
        await refreshTodayRecordOnly()
    }

    private func addStrengthRecord(_ draft: StrengthSessionDraft) async {
        do {
            _ = try await workoutService.createStrengthSession(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeSessionsIntoRecord(_ sessions: [WorkoutSession]) -> WorkoutRecord? {
        let exercises = sessions.flatMap(\.exercises)
        guard !exercises.isEmpty else { return nil }
        return WorkoutRecord(id: sessions.first?.id ?? "today-record", exercises: exercises)
    }

    private func moveLiveWorkoutCursor(toNextIncompleteSetIn session: inout PlanLiveWorkoutSession) {
        for exerciseIndex in session.exercises.indices {
            for setIndex in session.exercises[exerciseIndex].sets.indices {
                let setId = session.exercises[exerciseIndex].sets[setIndex].id
                guard !session.completedSetIds.contains(setId) else { continue }
                session.currentExerciseIndex = exerciseIndex
                session.currentSetIndex = setIndex
                return
            }
        }

        session.currentExerciseIndex = max(session.exercises.count - 1, 0)
        session.currentSetIndex = max(session.exercises.last?.sets.count ?? 1, 1) - 1
    }

    private func markLiveSetCompleted(planSetId: String) {
        guard var session = activeLiveWorkout else { return }
        session.completedSetIds.insert(planSetId)
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        Task { await liveActivityManager.update(session: session) }
    }

    private func isPlanSetCompletedInTodayPlan(_ planSetId: String) -> Bool {
        todayPlan?.exercises
            .flatMap(\.sets)
            .first { $0.id == planSetId }?
            .isCompleted == true
    }

    private func optimisticWorkoutRecord(from session: PlanLiveWorkoutSession) -> WorkoutRecord? {
        let exercises = session.exercises.compactMap { exercise -> Exercise? in
            let sets = exercise.sets
                .filter { session.completedSetIds.contains($0.id) }
                .enumerated()
                .map { index, set in
                    ExerciseSet(
                        id: set.id,
                        setIndex: index + 1,
                        weight: set.targetWeight,
                        weightUnit: set.targetWeightUnit,
                        reps: set.targetReps,
                        rpe: nil
                    )
                }
            guard !sets.isEmpty else { return nil }
            return Exercise(id: exercise.id, name: exercise.name, sets: sets)
        }

        guard !exercises.isEmpty else { return nil }
        return WorkoutRecord(id: "live-\(session.id)", exercises: exercises)
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

    static func currentPlanDateString(
        now: Date = Date(),
        formatter: WorkoutDateFormatter = WorkoutDateFormatter()
    ) -> String {
        formatter.string(from: now)
    }
}
