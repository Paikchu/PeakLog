import Foundation
import Combine

// `PlanLiveWorkoutSet` / `PlanLiveWorkoutExercise` / `PlanLiveWorkoutSession`
// 见 `Models/PlanLiveWorkoutModels.swift`。

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
    // 本次休息的起点，与 restEndDate 一起构成休息面板进度条的区间。
    @Published var restStartDate: Date?
    /// 最近一次「结束并保存」生成的训练小结；同一天内保留，供 dock 入口重新打开。
    @Published var sessionSummary: TrainingSessionSummary?
    /// 小结弹层的显隐；confirm 成功后自动置 true，用户也可从 dock 重新打开。
    @Published var isPresentingSessionSummary = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Flips true after the first successful `refresh()`. Gates the
    /// full-page `ProgressView` swap in `TodayWorkoutScreen` to the initial
    /// load only — once the screen has real content, a background refresh
    /// (e.g. re-entering the tab, or an error-recovery reload) updates
    /// `todayPlan`/`todayRecord`/`runningRecords` in place instead of
    /// flashing the whole page back to a spinner.
    private(set) var hasLoadedOnce = false

    /// 训练记录写入（或删除）成功后调用；宿主用它刷新自己那份派生状态。
    /// 与 `FutureDayPlanEditorViewModel.onPlanChanged` 同一套路：写路径在
    /// 这边，刷新交给持有 `HistoryViewModel` 的视图层接线（见
    /// `TrainingScreen`），今日页因此不必知道日历的存在。
    ///
    /// 只在能改变"某天有没有记录"的写路径上触发——即会影响周条/月网格
    /// 实心圆点的那些。改重量/次数一类不改变这个事实的编辑不触发。
    var onWorkoutDataChanged: (() async -> Void)?

    private let trainingPlanService: TrainingPlanServiceProtocol
    private let workoutService: WorkoutServiceProtocol
    private let liveActivityManager: PlanLiveActivityManaging
    /// 只用于结束训练时取 PR 基线与单位偏好；为 nil（测试默认）时小结仍会生成，
    /// 只是不做 PR 判定、单位回落到 kg。
    private let profileService: ProfileServiceProtocol?
    /// 只用于给专注卡片补「上次成绩」；为 nil 时卡片少一行上下文，不影响训练流程。
    private let exerciseLibraryService: ExerciseLibraryServiceProtocol?
    private var previousPerformanceTask: Task<Void, Never>?

    private var liveActivityObservationTask: Task<Void, Never>?
    private var restCountdownTask: Task<Void, Never>?
    private var persistDebounceTask: Task<Void, Never>?
    /// 训练中被快速改过、尚未写库的计划组目标值，按 planSetId 去重——连点 `+` 只留最后一档。
    private var pendingPlanSetTargets: [String: PendingPlanSetTarget] = [:]
    private var planSetTargetWriteTask: Task<Void, Never>?
    private let sessionDefaults: UserDefaults

    static let restDurationSeconds: TimeInterval = 90
    private static let persistedSessionKey = "today.live_workout_session.v1"
    // 训练集频繁勾选/取消时，避免每次都在主线程同步做 JSONEncoder + UserDefaults.set。
    // 中途的每次变更都重新计时，写盘只在变更停止这段延迟后发生一次。
    private static let persistDebounceDelay: Duration = .milliseconds(400)
    // ± 连点比勾选更密（加 10kg 就是连点 4 下），窗口相应放宽一点。
    private static let planSetTargetWriteDelay: Duration = .milliseconds(600)

    init(
        trainingPlanService: TrainingPlanServiceProtocol,
        workoutService: WorkoutServiceProtocol,
        liveActivityManager: PlanLiveActivityManaging = NoOpPlanLiveActivityManager(),
        sessionDefaults: UserDefaults = .standard,
        profileService: ProfileServiceProtocol? = nil,
        exerciseLibraryService: ExerciseLibraryServiceProtocol? = nil
    ) {
        self.trainingPlanService = trainingPlanService
        self.workoutService = workoutService
        self.liveActivityManager = liveActivityManager
        self.sessionDefaults = sessionDefaults
        self.profileService = profileService
        self.exerciseLibraryService = exerciseLibraryService
    }

    #if !TESTING
    convenience init() {
        self.init(
            trainingPlanService: AppServices.trainingPlanService,
            workoutService: AppServices.workoutService,
            liveActivityManager: PlanLiveActivityManagerFactory.make(),
            profileService: AppServices.profileService,
            exerciseLibraryService: AppServices.exerciseLibraryService
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
        todayPlan?.exercises.contains {
            $0.isCardioCompleted || $0.sets.contains(where: { $0.isCompleted })
        } ?? false
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
            .filter { $0.itemType == .strength && !$0.sets.isEmpty }
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
                    },
                    exerciseId: exercise.exerciseId,
                    previousPerformanceSummary: exercise.previousPerformanceSummary,
                    aiSuggestion: exercise.aiSuggestion,
                    notes: exercise.notes
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
            skippedExerciseIds: [],
            startedAt: Date()
        )
        moveLiveWorkoutCursor(toNextIncompleteSetIn: &session)
        activeLiveWorkout = session
        // 关键节点：立即落盘，不经过去抖延迟。
        persistActiveLiveWorkoutImmediately()
        isTrainingFocusActive = true
        Task { await liveActivityManager.start(session: session) }
        observeLiveActivityCompletions(sessionId: session.id)
        fillPreviousPerformanceSummaries(sessionId: session.id)
    }

    /// 开练后异步补「上次成绩」。放在 session 建立之后而不是阻塞开始训练：
    /// 查历史要读全部力量记录，不该让用户等；补不到就少一行上下文。
    private func fillPreviousPerformanceSummaries(sessionId: String) {
        guard let exerciseLibraryService else { return }
        previousPerformanceTask?.cancel()

        let lookups = (activeLiveWorkout?.exercises ?? [])
            .filter { $0.previousPerformanceSummary?.isEmpty ?? true }
            .map { (id: $0.id, exerciseId: $0.exerciseId, name: $0.name) }
        guard !lookups.isEmpty else { return }

        previousPerformanceTask = Task { @MainActor [weak self] in
            let today = Date()
            for lookup in lookups {
                guard !Task.isCancelled else { return }
                let sets = await exerciseLibraryService.fetchLastPerformedSets(
                    exerciseId: lookup.exerciseId,
                    exerciseName: lookup.name,
                    before: today
                )
                guard !Task.isCancelled,
                      let self,
                      let summary = sets.flatMap(PreviousPerformanceText.summary(from:)),
                      var session = self.activeLiveWorkout,
                      session.id == sessionId,
                      let index = session.exercises.firstIndex(where: { $0.id == lookup.id })
                else { continue }

                session.exercises[index].previousPerformanceSummary = summary
                self.activeLiveWorkout = session
            }
        }
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
        restStartDate = nil
    }

    /// 休息中追加时长（默认 +30s）；不在休息时无操作。
    func extendRest(by seconds: TimeInterval = 30) {
        guard let endDate = restEndDate, endDate > Date() else { return }
        let newEndDate = endDate.addingTimeInterval(seconds)
        restEndDate = newEndDate
        scheduleRestExpiry(at: newEndDate)
    }

    private func startRestCountdownIfNeeded() {
        guard isTrainingFocusActive, activeLiveWorkout?.isComplete == false else {
            skipRest()
            return
        }

        let endDate = Date().addingTimeInterval(Self.restDurationSeconds)
        restStartDate = Date()
        restEndDate = endDate
        scheduleRestExpiry(at: endDate)
    }

    private func scheduleRestExpiry(at endDate: Date) {
        restCountdownTask?.cancel()
        restCountdownTask = Task { @MainActor [weak self] in
            let interval = endDate.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            guard let self, self.restEndDate == endDate else { return }
            self.restEndDate = nil
            self.restStartDate = nil
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

    /// 训练进行中快速改某一组的目标负重与次数（专注卡片上的 ± 与数值轮盘都走这里）。
    ///
    /// 为什么要同时写 session 和计划两处：`confirmPlanLiveWorkout` 落库时读的是
    /// **session 快照**（`set.targetWeight` / `set.targetReps`），所以 session 决定这次
    /// 训练最终记下什么；而浏览模式的卡片、最小化后的进度、以及后续的计划展示读的是
    /// `todayPlan`。只改一边，两边就会各说各话——用户改成 65kg，训练记录记 65，
    /// 退出专注模式却看到计划还写着 60。
    ///
    /// session 侧立即生效（UI 与落库值都不等待），计划侧的写库走去抖：`+` / `−` 是
    /// 连点操作，每一下都发一次写请求既无意义，又会在计划编辑流水里堆出一串中间态。
    func updateLiveWorkoutSet(setId: String, targetWeight: Double?, targetReps: Int) {
        let weight = QuickSetAdjustment.clampedWeight(targetWeight)
        let reps = QuickSetAdjustment.clampedReps(targetReps)
        guard let unit = applyTargetToLiveSession(setId: setId, targetWeight: weight, targetReps: reps)
        else { return }

        // 计划侧：本地先乐观更新（浏览模式立刻一致），写库延后合并。
        updatePlanSetInPlace(planSetId: setId) { plannedSet in
            plannedSet.targetWeight = weight
            plannedSet.targetReps = reps
        }
        schedulePlanSetTargetWrite(
            planSetId: setId,
            target: PendingPlanSetTarget(
                targetWeight: weight,
                targetWeightUnit: unit,
                targetReps: reps
            )
        )
    }

    /// 把新的目标值打进进行中的 session 快照，返回这一组的单位（表示"改成功了"）；
    /// 没有进行中的训练、找不到这一组、组已落库或值没变化时返回 nil。
    ///
    /// 两个入口共用它：专注卡片的快速修改，以及最小化训练时在普通计划卡上的编辑
    /// （`updatePlannedSet`）。后者以前不碰 session——而 confirm 落库读的正是 session
    /// 快照，于是那次编辑会在结束训练时被悄悄丢掉，记进去的还是旧数字。
    @discardableResult
    private func applyTargetToLiveSession(
        setId: String,
        targetWeight: Double?,
        targetReps: Int,
        targetWeightUnit: WeightUnit? = nil
    ) -> WeightUnit? {
        guard var session = activeLiveWorkout,
              let exerciseIndex = session.exercises.firstIndex(where: { exercise in
                  exercise.sets.contains { $0.id == setId }
              }),
              let setIndex = session.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId })
        else { return nil }

        // 进入 session 前就已落库的组：它的真实成绩已经在训练记录里，这里再改目标值
        // 只会让两者对不上。和"已落库的组不允许在 session 内撤销"是同一条边界。
        let current = session.exercises[exerciseIndex].sets[setIndex]
        guard !current.isAlreadyCompleted else { return nil }

        let unit = targetWeightUnit ?? current.targetWeightUnit
        guard targetWeight != current.targetWeight
                || targetReps != current.targetReps
                || unit != current.targetWeightUnit
        else { return nil }

        session.exercises[exerciseIndex].sets[setIndex].targetWeight = targetWeight
        session.exercises[exerciseIndex].sets[setIndex].targetWeightUnit = unit
        session.exercises[exerciseIndex].sets[setIndex].targetReps = targetReps
        activeLiveWorkout = session

        Task { await liveActivityManager.update(session: session) }
        return unit
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
        previousPerformanceTask?.cancel()
        previousPerformanceTask = nil
        // 取消的是"这次训练"，不是"这些改动"：用户在专注卡片上把目标从 60 改到 65
        // 是对计划的判断，session 丢掉后这份判断仍然该留在今天的计划里。
        Task { await flushPendingPlanSetTargets() }
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
        // 先把训练中改过的目标值写完，再落库这次训练：两者写的是同一批组，
        // 让它们排到 `completePlannedSet` 后面只会让计划编辑流水的顺序变得难读。
        await flushPendingPlanSetTargets()
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

        // PR 基线必须在本次训练落库之前取——落库后历史里已包含今天的组，
        // 「是否刷新纪录」就永远判不出来了。取不到（离线/未注入）则跳过 PR 判定。
        var priorPRs: [String: ExercisePR]?
        var preferredUnit = WeightUnit.kg
        if let profileService, let profile = try? await profileService.fetchProfile() {
            priorPRs = Dictionary(
                profile.exercisePRs.map { ($0.normalizedName, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            preferredUnit = profile.preferences.weightUnit
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
            previousPerformanceTask?.cancel()
            previousPerformanceTask = nil
            activeLiveWorkout = nil
            // 关键节点：立即落盘，不经过去抖延迟。
            persistActiveLiveWorkoutImmediately()
            isTrainingFocusActive = false
            skipRest()
            if let summary = TrainingSessionSummary.make(
                session: session,
                priorPRs: priorPRs,
                preferredUnit: preferredUnit,
                endedAt: Date()
            ) {
                sessionSummary = summary
                isPresentingSessionSummary = true
            }
            await liveActivityManager.end()
            await refreshTodayRecordOnly()
            if todayRecord == nil {
                todayRecord = optimisticWorkoutRecord(from: session)
            }
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }

        // 成功与失败都通知：失败时也可能已经落库了一部分组（循环在中途
        // 抛错），日历圆点该跟着库里的真实状态走。
        await onWorkoutDataChanged?()
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

        // 失败路径同样通知：completePlannedSet 可能已经成功、只是随后的
        // RPE 写入抛错，那一组记录已经存在了。
        await onWorkoutDataChanged?()
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
        // 训练最小化时用户仍能在普通计划卡上改这一组，那次编辑同样要进 session 快照。
        applyTargetToLiveSession(
            setId: planSetId,
            targetWeight: targetWeight,
            targetReps: targetReps,
            targetWeightUnit: targetWeightUnit
        )

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

    /// 批量调节本动作所有未完成组的目标（只改重量 / 只改次数 / 两者都改）。
    /// 乐观更新与落库共用 `PlannedSetBatchAdjustment.applied(to:)`，界面先变的
    /// 值就是库里最终写下的值；失败沿用单组编辑的处理：报错 + `refresh()`
    /// 拉回真实状态。已完成组不参与，与本地库的写入规则一致。
    ///
    /// 注意：与单组编辑一样，这里不改写进行中训练（`activeLiveWorkout`）里那份
    /// 组快照——专注模式的卡片仍显示开练时的目标，直到下一次开始训练才重新取值。
    func batchUpdatePlannedSets(
        planExerciseId: String,
        adjustment: PlannedSetBatchAdjustment
    ) async {
        guard !adjustment.isEmpty else { return }
        updatePlanExerciseInPlace(planExerciseId: planExerciseId) { exercise in
            for index in exercise.sets.indices where !exercise.sets[index].isCompleted {
                exercise.sets[index] = adjustment.applied(to: exercise.sets[index])
            }
        }

        do {
            let updated = try await trainingPlanService.batchUpdatePlannedSets(
                planExerciseId: planExerciseId,
                adjustment: adjustment
            )
            updatePlanExerciseInPlace(planExerciseId: planExerciseId) { exercise in
                exercise.sets = updated.sets
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

        // 级联删除可能把当天清空，圆点要跟着消失。
        await onWorkoutDataChanged?()
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

        // 删掉最后一组可能把当天清空。
        await onWorkoutDataChanged?()
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

        // 删掉最后一个动作可能把当天清空。
        await onWorkoutDataChanged?()
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
        await onWorkoutDataChanged?()
        return record
    }

    func completePlannedCardio(planExerciseId: String, metrics: CardioMetrics) async throws {
        _ = try await trainingPlanService.completePlannedCardio(
            planExerciseId: planExerciseId,
            metrics: metrics
        )
        await refresh()
        await onWorkoutDataChanged?()
    }

    func addDailyRecord(_ draft: DailyRecordDraft) async throws {
        switch draft {
        case .strength(let strengthDraft):
            try await addStrengthRecord(strengthDraft)
        case .cardio(let metrics):
            let record = try await workoutService.createCardioRecord(
                workoutDate: Date(),
                metrics: metrics,
                source: .manual
            )
            runningRecords.append(record)
        }
        await refreshTodayRecordOnly()
        await onWorkoutDataChanged?()
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

    private struct PendingPlanSetTarget {
        let targetWeight: Double?
        let targetWeightUnit: WeightUnit
        let targetReps: Int
    }

    /// 与 `schedulePersistActiveLiveWorkout` 同一套去抖思路，但这里防的是写库与请求乱序：
    /// 每次 `+` 都起一个独立的 `Task` 去写，它们的完成顺序不受控，最后落库的可能是中间那一档。
    /// 取消 + 重排后只有最后一次会真正执行，也就只有用户停手时的那个值会写进去。
    private func schedulePlanSetTargetWrite(planSetId: String, target: PendingPlanSetTarget) {
        pendingPlanSetTargets[planSetId] = target
        planSetTargetWriteTask?.cancel()
        planSetTargetWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.planSetTargetWriteDelay)
            guard !Task.isCancelled, let self else { return }
            // 先摘掉自己的引用再写：否则等下那个公开 flush 若在写库期间被调用，
            // 会 cancel 掉「正在执行这次写入」的任务，让写请求带着已取消的
            // 任务上下文跑完剩下的 await。
            self.planSetTargetWriteTask = nil
            await self.writePendingPlanSetTargets()
        }
    }

    /// 把去抖窗口里积压的目标值写库。结束/取消训练、App 退到后台时都要先走一遍，
    /// 否则"用户看到的数"和"库里的数"会因为一次挂起就永久分叉。
    func flushPendingPlanSetTargets() async {
        planSetTargetWriteTask?.cancel()
        planSetTargetWriteTask = nil
        await writePendingPlanSetTargets()
    }

    private func writePendingPlanSetTargets() async {
        let pending = pendingPlanSetTargets
        pendingPlanSetTargets = [:]
        guard !pending.isEmpty else { return }

        for (planSetId, target) in pending {
            do {
                let updated = try await trainingPlanService.updatePlannedSet(
                    planSetId: planSetId,
                    targetWeight: target.targetWeight,
                    targetWeightUnit: target.targetWeightUnit,
                    targetReps: target.targetReps
                )
                // 写库期间用户可能又点了几下 `+`：本地已经是更新后的值，别拿这次
                // 请求的回声把它盖回去——更新的那次写入还在去抖队列里排着。
                guard pendingPlanSetTargets[planSetId] == nil else { continue }
                updatePlanSetInPlace(planSetId: planSetId) { plannedSet in
                    plannedSet.targetWeight = updated.targetWeight
                    plannedSet.targetWeightUnit = updated.targetWeightUnit
                    plannedSet.targetReps = updated.targetReps
                }
            } catch {
                // 刻意不像 `updatePlannedSet` 那样 `await refresh()`：训练进行中把计划整份
                // 拉回来，会用服务端的旧目标值盖掉用户刚在专注卡片上改的数。session 快照
                // 才是这次训练要落库的那一份，它不受这次失败影响，报错即可。
                errorMessage = error.localizedDescription
            }
        }
    }

    /// App 即将失活/进入后台时调用：若组勾选去抖窗口内还有待落盘的写入，立即执行，
    /// 避免用户刚勾选完一个组、App 恰好在 400ms 窗口内被系统挂起/杀掉导致这次变更
    /// 丢失——这正是去抖优化本身要小心避免引入的回归。调用方是 `ContentView` 对
    /// `scenePhase` 转为 `.background`/`.inactive` 的观察（`TodayWorkoutViewModel`
    /// 自身不持有/观察 `scenePhase`，遵循现有由承载视图转发场景事件的模式）。
    func flushPendingLiveWorkoutPersistence() {
        persistActiveLiveWorkoutImmediately()
        // 同一个理由的另一半：训练中快速改过的目标值可能还压在写库去抖窗口里。
        // 落盘的 session 已经带上了新值，但计划侧要靠这次 flush 才追得上。
        Task { await flushPendingPlanSetTargets() }
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
        // 旧版本落盘的 session 没有上下文字段，恢复后同样补一次。
        fillPreviousPerformanceSummaries(sessionId: session.id)
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

    private func updatePlanExerciseInPlace(
        planExerciseId: String,
        update: (inout TrainingPlanExercise) -> Void
    ) {
        guard var plan = todayPlan,
              let exerciseIndex = plan.exercises.firstIndex(where: { $0.id == planExerciseId })
        else { return }
        update(&plan.exercises[exerciseIndex])
        todayPlan = plan
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

    /// `nonisolated`: a pure date-to-day-key helper that happens to live on the
    /// view model. Nothing about it touches main-actor state.
    nonisolated static func currentPlanDateString(
        now: Date = Date(),
        formatter: WorkoutDateFormatter = WorkoutDateFormatter()
    ) -> String {
        formatter.string(from: now)
    }
}
