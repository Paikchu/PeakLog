import Foundation
import Combine
import CoreGraphics

struct PlanLiveWorkoutSet: Identifiable, Equatable, Codable {
    let id: String
    let setIndex: Int
    let targetWeight: Double?
    let targetWeightUnit: WeightUnit
    let targetReps: Int
    let isAlreadyCompleted: Bool
}

struct PlanLiveWorkoutExercise: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let loadType: ExerciseLoadType
    let sets: [PlanLiveWorkoutSet]
}

struct PlanLiveWorkoutSession: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let focus: String?
    var exercises: [PlanLiveWorkoutExercise]
    var currentExerciseIndex: Int
    var currentSetIndex: Int
    var completedSetIds: Set<String>
    // 用户滑动锁定优先完成的动作；做完后清除，指针回到最早未完成动作。
    var manualFocusExerciseId: String?
    var skippedExerciseIds: Set<String> = []

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

    func exercise(withId id: String) -> PlanLiveWorkoutExercise? {
        exercises.first { $0.id == id }
    }

    func firstIncompleteSetIndex(in exercise: PlanLiveWorkoutExercise) -> Int? {
        exercise.sets.firstIndex { !completedSetIds.contains($0.id) }
    }

    func completedSetsCount(in exercise: PlanLiveWorkoutExercise) -> Int {
        exercise.sets.count { completedSetIds.contains($0.id) }
    }

    func isExerciseComplete(_ exercise: PlanLiveWorkoutExercise) -> Bool {
        firstIncompleteSetIndex(in: exercise) == nil
    }
}

@MainActor
final class TodayWorkoutViewModel: ObservableObject {
    @Published var runningRecords: [RunningWorkoutRecord] = []
    @Published var todayPlan: TrainingPlanDay?
    @Published var todayRecord: WorkoutRecord?
    @Published var activeLiveWorkout: PlanLiveWorkoutSession? {
        didSet { persistActiveLiveWorkout() }
    }
    // 专注模式开关：session 存在但该值为 false 时是“最小化”状态（浏览模式 + 顶部训练横幅）。
    @Published var isTrainingFocusActive = false
    // 组间休息倒计时结束时间；nil 表示不在休息。
    @Published var restEndDate: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let trainingPlanService: TrainingPlanServiceProtocol
    private let workoutService: WorkoutServiceProtocol
    private let liveActivityManager: PlanLiveActivityManaging

    private var liveActivityObservationTask: Task<Void, Never>?
    private var restCountdownTask: Task<Void, Never>?
    private let sessionDefaults: UserDefaults

    static let restDurationSeconds: TimeInterval = 90
    private static let persistedSessionKey = "today.live_workout_session.v1"

    init(
        trainingPlanService: TrainingPlanServiceProtocol,
        workoutService: WorkoutServiceProtocol,
        liveActivityManager: PlanLiveActivityManaging = NoOpPlanLiveActivityManager(),
        sessionDefaults: UserDefaults = .standard
    ) {
        self.trainingPlanService = trainingPlanService
        self.workoutService = workoutService
        self.liveActivityManager = liveActivityManager
        self.sessionDefaults = sessionDefaults
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
            restoreLiveWorkoutSessionIfNeeded()
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
            completedSetIds: Set(exercises.flatMap(\.sets).filter(\.isAlreadyCompleted).map(\.id)),
            manualFocusExerciseId: nil,
            skippedExerciseIds: []
        )
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        isTrainingFocusActive = true
        Task { await liveActivityManager.start(session: session) }
        observeLiveActivityCompletions(sessionId: session.id)
    }

    /// 用户滑动停稳在另一个动作上：锁定该动作为当前动作，优先完成。
    func focusLiveExercise(id: String) {
        guard var session = activeLiveWorkout,
              let exercise = session.exercise(withId: id),
              session.firstIncompleteSetIndex(in: exercise) != nil,
              session.currentExercise?.id != id
        else { return }

        session.manualFocusExerciseId = id
        session.skippedExerciseIds.remove(id)
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        Task { await liveActivityManager.update(session: session) }
    }

    /// 跳过当前动作：沉到队尾，指针流转到下一个未跳过的未完成动作。
    func skipCurrentLiveExercise() {
        guard var session = activeLiveWorkout, let current = session.currentExercise else { return }
        session.skippedExerciseIds.insert(current.id)
        if session.manualFocusExerciseId == current.id {
            session.manualFocusExerciseId = nil
        }
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        Task { await liveActivityManager.update(session: session) }
    }

    func minimizeTrainingFocus() {
        isTrainingFocusActive = false
    }

    func resumeTrainingFocus() {
        guard activeLiveWorkout != nil else { return }
        isTrainingFocusActive = true
    }

    func skipRest() {
        restCountdownTask?.cancel()
        restCountdownTask = nil
        restEndDate = nil
    }

    private func startRestCountdownIfNeeded() {
        guard isTrainingFocusActive, activeLiveWorkout?.isComplete == false else {
            skipRest()
            return
        }

        restCountdownTask?.cancel()
        let endDate = Date().addingTimeInterval(Self.restDurationSeconds)
        restEndDate = endDate
        restCountdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.restDurationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.restEndDate == endDate else { return }
            self.restEndDate = nil
        }
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
        guard var session = activeLiveWorkout, let set = session.currentSet,
              !session.completedSetIds.contains(set.id) else { return }
        session.completedSetIds.insert(set.id)
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        startRestCountdownIfNeeded()
        Task { await liveActivityManager.update(session: session) }
    }

    func toggleLiveSet(setId: String) {
        guard var session = activeLiveWorkout else { return }
        var didCompleteSet = false
        if session.completedSetIds.contains(setId) {
            // 已落库的组不允许在 session 内撤销，否则 confirm 后界面与库不一致。
            guard session.exercises.flatMap(\.sets).first(where: { $0.id == setId })?.isAlreadyCompleted != true else { return }
            session.completedSetIds.remove(setId)
        } else {
            session.completedSetIds.insert(setId)
            didCompleteSet = true
        }
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        if didCompleteSet {
            startRestCountdownIfNeeded()
        }
        Task { await liveActivityManager.update(session: session) }
    }

    func cancelPlanLiveWorkout() {
        liveActivityObservationTask?.cancel()
        liveActivityObservationTask = nil
        activeLiveWorkout = nil
        isTrainingFocusActive = false
        skipRest()
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
            isTrainingFocusActive = false
            skipRest()
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
        // 1. 手动锁定的动作优先；做完即释放锁，回到最早未完成动作。
        if let manualId = session.manualFocusExerciseId {
            if let exerciseIndex = session.exercises.firstIndex(where: { $0.id == manualId }),
               let setIndex = session.firstIncompleteSetIndex(in: session.exercises[exerciseIndex]) {
                session.currentExerciseIndex = exerciseIndex
                session.currentSetIndex = setIndex
                return
            }
            session.manualFocusExerciseId = nil
        }

        // 2. 按 plan 顺序第一个未跳过的未完成动作；3. 全被跳过时回落到含跳过的。
        for allowSkipped in [false, true] {
            for exerciseIndex in session.exercises.indices {
                let exercise = session.exercises[exerciseIndex]
                if !allowSkipped, session.skippedExerciseIds.contains(exercise.id) { continue }
                guard let setIndex = session.firstIncompleteSetIndex(in: exercise) else { continue }
                session.currentExerciseIndex = exerciseIndex
                session.currentSetIndex = setIndex
                return
            }
        }

        session.currentExerciseIndex = max(session.exercises.count - 1, 0)
        session.currentSetIndex = max(session.exercises.last?.sets.count ?? 1, 1) - 1
    }

    private struct PersistedLiveWorkout: Codable {
        let planDate: String
        let session: PlanLiveWorkoutSession
    }

    /// Session 随每次变更写盘，App 被杀后同一天可恢复；confirm/cancel 置 nil 即清除。
    private func persistActiveLiveWorkout() {
        guard let session = activeLiveWorkout else {
            sessionDefaults.removeObject(forKey: Self.persistedSessionKey)
            return
        }

        let persisted = PersistedLiveWorkout(planDate: Self.currentPlanDateString(), session: session)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        sessionDefaults.set(data, forKey: Self.persistedSessionKey)
    }

    private func restoreLiveWorkoutSessionIfNeeded() {
        guard activeLiveWorkout == nil,
              let data = sessionDefaults.data(forKey: Self.persistedSessionKey),
              let persisted = try? JSONDecoder().decode(PersistedLiveWorkout.self, from: data)
        else { return }

        guard persisted.planDate == Self.currentPlanDateString(), let plan = todayPlan else {
            sessionDefaults.removeObject(forKey: Self.persistedSessionKey)
            return
        }

        // 计划被改动（组被删除等）导致 session 内的组对不上时放弃恢复。
        let planSetIds = Set(plan.exercises.flatMap(\.sets).map(\.id))
        var session = persisted.session
        let sessionSetIds = Set(session.exercises.flatMap(\.sets).map(\.id))
        guard sessionSetIds.isSubset(of: planSetIds) else {
            sessionDefaults.removeObject(forKey: Self.persistedSessionKey)
            return
        }

        // 期间通过其他途径落库的组并入完成集合。
        let planCompletedIds = Set(plan.exercises.flatMap(\.sets).filter(\.isCompleted).map(\.id))
        session.completedSetIds.formUnion(planCompletedIds.intersection(sessionSetIds))
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        // 恢复为最小化状态：由用户从横幅/dock 主动回到专注模式。
        isTrainingFocusActive = false
        Task { await liveActivityManager.start(session: session) }
        observeLiveActivityCompletions(sessionId: session.id)
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
