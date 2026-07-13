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
        didSet { schedulePersistActiveLiveWorkout() }
    }
    // 专注模式开关：session 存在但该值为 false 时是“最小化”状态（浏览模式 + 顶部训练横幅）。
    @Published var isTrainingFocusActive = false
    // 组间休息倒计时结束时间；nil 表示不在休息。
    @Published var restEndDate: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Flips true after the first successful `refresh()`. Gates the
    /// full-page `ProgressView` swap in `TodayWorkoutScreen` to the initial
    /// load only — once the screen has real content, a background refresh
    /// (e.g. re-entering the tab, or an error-recovery reload) updates
    /// `todayPlan`/`todayRecord`/`runningRecords` in place instead of
    /// flashing the whole page back to a spinner.
    private(set) var hasLoadedOnce = false

    private let trainingPlanService: TrainingPlanServiceProtocol
    private let workoutService: WorkoutServiceProtocol
    private let liveActivityManager: PlanLiveActivityManaging

    private var liveActivityObservationTask: Task<Void, Never>?
    private var restCountdownTask: Task<Void, Never>?
    private var persistDebounceTask: Task<Void, Never>?
    private let sessionDefaults: UserDefaults

    static let restDurationSeconds: TimeInterval = 90
    private static let persistedSessionKey = "today.live_workout_session.v1"
    // 训练集频繁勾选/取消时，避免每次都在主线程同步做 JSONEncoder + UserDefaults.set。
    // 中途的每次变更都重新计时，写盘只在变更停止这段延迟后发生一次。
    private static let persistDebounceDelay: Duration = .milliseconds(400)

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
        // Always refresh: the previous guard only loaded once per view
        // lifetime, so switching away and back (or a partial first load
        // where only one of plan/record/runningRecords came back non-empty)
        // left the screen showing stale data forever. `.task` only re-fires
        // when the screen re-enters the hierarchy, so this isn't a hot path.
        await refresh()
    }

    func refresh() async {
        // Only the very first (successful-or-not) load shows the full-page
        // spinner. Once `hasLoadedOnce` is true, every later refresh —
        // triggered by re-entering the screen or by an error-recovery path
        // — updates state in place without toggling `isLoading`, so
        // `TodayWorkoutScreen` keeps rendering the already-loaded content
        // instead of flashing back to `ProgressView`.
        let isInitialLoad = !hasLoadedOnce
        if isInitialLoad {
            isLoading = true
        }
        defer {
            if isInitialLoad {
                isLoading = false
            }
        }

        do {
            async let plan = trainingPlanService.fetchTodayPlan()
            async let sessions = workoutService.sessionsForDay(Date())
            async let records = workoutService.runningRecordsForDay(Date())
            let (loadedPlan, loadedSessions, loadedRecords) = try await (plan, sessions, records)
            runningRecords = loadedRecords
            todayPlan = loadedPlan
            todayRecord = mergeSessionsIntoRecord(loadedSessions)
            restoreLiveWorkoutSessionIfNeeded()
            hasLoadedOnce = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True once any of today's planned sets is completed — used to gray out the
    /// one-tap signals that only make sense on an untrained day (the server's
    /// C31 would reject them regardless).
    var todayHasCompletedSets: Bool {
        todayPlan?.exercises.contains { $0.sets.contains(where: { $0.isCompleted }) } ?? false
    }

    /// Records a one-tap mid-week signal locally (Phase 3) so it reaches the
    /// learning loop even if the subsequent server replan fails. The actual
    /// plan change is applied server-side and arrives via the next pull.
    func recordDaySignal(_ signal: ReplanSignal) async {
        do {
            try await trainingPlanService.recordDaySignal(signal)
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
        // 关键节点：立即落盘，不经过去抖延迟。
        persistActiveLiveWorkoutImmediately()
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
        // 关键节点：立即落盘，不经过去抖延迟。
        persistActiveLiveWorkoutImmediately()
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
            // 关键节点：立即落盘，不经过去抖延迟。
            persistActiveLiveWorkoutImmediately()
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

    @discardableResult
    func addPlanExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay {
        guard !drafts.isEmpty else { throw NSError(domain: "TodayWorkout", code: 1) }
        let updatedDay = try await trainingPlanService.addPlannedExercises(drafts)
        todayPlan = updatedDay
        return updatedDay
    }

    /// 训练进行中（专注模式或最小化态）时不生效；UI 层已阻止长按进入重排模式，此处只做兜底。
    func reorderTodayPlanExercises(orderedExerciseIds: [String]) async {
        guard activeLiveWorkout == nil, let plan = todayPlan else { return }
        let previous = plan.exercises
        let optimistic = orderedExerciseIds.compactMap { id in previous.first { $0.id == id } }
        guard optimistic.count == previous.count else { return }
        todayPlan?.exercises = optimistic

        do {
            let updated = try await trainingPlanService.reorderPlannedExercises(orderedExerciseIds: orderedExerciseIds)
            todayPlan = updated
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
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

    func deletePlanExercise(planExerciseId: String) async {
        guard var plan = todayPlan, plan.exercises.contains(where: { $0.id == planExerciseId }) else { return }
        plan.exercises.removeAll { $0.id == planExerciseId }
        for index in plan.exercises.indices {
            plan.exercises[index].orderIndex = index
        }
        todayPlan = plan
        removeExerciseFromLiveSession(planExerciseId)

        do {
            try await trainingPlanService.deletePlannedExercise(planExerciseId: planExerciseId)
            // 已完成组关联的记录会被级联删除，同步刷新记录区。
            await refreshTodayRecordOnly()
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    /// 删除计划动作时同步从进行中的训练 session 移除；动作删空则整个训练取消。
    private func removeExerciseFromLiveSession(_ planExerciseId: String) {
        guard var session = activeLiveWorkout,
              let index = session.exercises.firstIndex(where: { $0.id == planExerciseId }) else { return }
        let removedSetIds = Set(session.exercises[index].sets.map(\.id))
        session.exercises.remove(at: index)
        session.completedSetIds.subtract(removedSetIds)
        session.skippedExerciseIds.remove(planExerciseId)
        if session.manualFocusExerciseId == planExerciseId {
            session.manualFocusExerciseId = nil
        }
        guard !session.exercises.isEmpty else {
            cancelPlanLiveWorkout()
            return
        }
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        Task { await liveActivityManager.update(session: session) }
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

    func deleteLoggedExercise(exerciseId: String) async {
        guard var record = todayRecord, record.exercises.contains(where: { $0.id == exerciseId }) else { return }
        let sessionId = record.id
        record.exercises.removeAll { $0.id == exerciseId }
        todayRecord = record.exercises.isEmpty ? nil : record

        do {
            try await workoutService.deleteExercise(sessionId: sessionId, exerciseId: exerciseId)
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

    @discardableResult
    func addRunningRecord(durationMinutes: Int, distanceKm: Double) async throws -> RunningWorkoutRecord {
        let record = try await workoutService.createRunningRecord(
            workoutDate: Date(),
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            source: .manual
        )
        runningRecords.append(record)
        runningRecords.sort { $0.createdAt < $1.createdAt }
        return record
    }

    func addDailyRecord(_ draft: DailyRecordDraft) async throws {
        switch draft {
        case .strength(let strengthDraft):
            try await addStrengthRecord(strengthDraft)
        case .cardio(let durationMinutes, let distanceKm):
            try await addRunningRecord(durationMinutes: durationMinutes, distanceKm: distanceKm)
        }
        await refreshTodayRecordOnly()
    }

    private func addStrengthRecord(_ draft: StrengthSessionDraft) async throws {
        _ = try await workoutService.createStrengthSession(draft)
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

    /// 去抖：取消前一次待执行的写入并重新计时，真正的落盘发生在连续变更停止之后。
    /// `activeLiveWorkout` 的类型未显式声明 `Sendable`，所以这里刻意不把编码/写盘挪
    /// 到后台队列——`Task { }` 在 `@MainActor` 方法里创建时继承调用方的 Main Actor
    /// 隔离，编码与写盘仍在主线程完成，只是被去抖延迟，不再阻塞式地随每次勾选执行。
    private func schedulePersistActiveLiveWorkout() {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistDebounceDelay)
            guard !Task.isCancelled else { return }
            self?.persistActiveLiveWorkout()
        }
    }

    /// 关键节点（开始/确认/取消训练）绕过去抖立即落盘：这些操作本就低频，且如果 App
    /// 恰好在去抖延迟窗口内被杀，用户不该丢失"已开始/已确认/已取消"这类状态。
    private func persistActiveLiveWorkoutImmediately() {
        persistDebounceTask?.cancel()
        persistDebounceTask = nil
        persistActiveLiveWorkout()
    }

    /// App 即将失活/进入后台时调用：若组勾选去抖窗口内还有待落盘的写入，立即执行，
    /// 避免用户刚勾选完一个组、App 恰好在 400ms 窗口内被系统挂起/杀掉导致这次变更
    /// 丢失——这正是去抖优化本身要小心避免引入的回归。调用方是 `ContentView` 对
    /// `scenePhase` 转为 `.background`/`.inactive` 的观察（`TodayWorkoutViewModel`
    /// 自身不持有/观察 `scenePhase`，遵循现有由承载视图转发场景事件的模式）。
    func flushPendingLiveWorkoutPersistence() {
        persistActiveLiveWorkoutImmediately()
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
            return Exercise(id: exercise.id, name: exercise.name, exerciseLoadType: exercise.loadType, sets: sets)
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
