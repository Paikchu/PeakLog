import Foundation

nonisolated private struct LocalAppState: Codable, Sendable {
    var profile: UserProfile
    var activePlan: TrainingPlan
    var strengthSessions: [WorkoutSession]
    var runningRecords: [RunningWorkoutRecord]
    var customExercises: [ExerciseDefinition]
    var goalSpec: GoalSpec?
    /// Not-yet-pushed edit events. Deliberately NOT overwritten by a pull
    /// (`replaceAll`) — a pull replaces cloud-mirrored *state*, but these are
    /// unpushed *facts*; overwriting them would silently lose history
    /// recorded while offline. See phase1 plan §4.3 / EV1.
    var pendingEditEvents: [PlanEditEvent]
    /// Monotonic counter backing `PlanEditEvent.clientSeq`. Persisted so a
    /// restart never reuses or rewinds a sequence number (EV3).
    var editEventSeq: Int64

    init(
        profile: UserProfile,
        activePlan: TrainingPlan,
        strengthSessions: [WorkoutSession],
        runningRecords: [RunningWorkoutRecord],
        customExercises: [ExerciseDefinition] = [],
        goalSpec: GoalSpec? = nil,
        pendingEditEvents: [PlanEditEvent] = [],
        editEventSeq: Int64 = 0
    ) {
        self.profile = profile
        self.activePlan = activePlan
        self.strengthSessions = strengthSessions
        self.runningRecords = runningRecords
        self.customExercises = customExercises
        self.goalSpec = goalSpec
        self.pendingEditEvents = pendingEditEvents
        self.editEventSeq = editEventSeq
    }

    // Custom decode keeps state files written before newer fields existed loadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(UserProfile.self, forKey: .profile)
        activePlan = try container.decode(TrainingPlan.self, forKey: .activePlan)
        strengthSessions = try container.decode([WorkoutSession].self, forKey: .strengthSessions)
        runningRecords = try container.decode([RunningWorkoutRecord].self, forKey: .runningRecords)
        customExercises = try container.decodeIfPresent([ExerciseDefinition].self, forKey: .customExercises) ?? []
        goalSpec = try container.decodeIfPresent(GoalSpec.self, forKey: .goalSpec)
        pendingEditEvents = try container.decodeIfPresent([PlanEditEvent].self, forKey: .pendingEditEvents) ?? []
        editEventSeq = try container.decodeIfPresent(Int64.self, forKey: .editEventSeq) ?? 0
    }
}

actor LocalAppDatabase {
    static let shared = LocalAppDatabase()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: LocalAppState

    /// Fired after a mutation persists locally, so the cloud syncer can push.
    /// Installed by `CloudSyncCoordinator` only when signed in; nil in DEBUG
    /// local mode, which keeps that mode fully offline. A full `replaceAll`
    /// (a pull writing cloud truth into the cache) deliberately does NOT fire
    /// it — otherwise every pull would echo straight back as a push.
    private var onChange: (@Sendable () -> Void)?

    /// The signed-in user plan-edit events are currently being recorded for.
    /// nil while signed out or in DEBUG local mode, which keeps both of those
    /// paths from accumulating events nobody will ever push (EV8).
    private var armedUserId: String?

    /// Events dropped by the soft cap this launch — diagnostic only, not
    /// persisted (EV12).
    private var droppedEditEventCount = 0

    private static let maxPendingEditEvents = 5000

    /// Arms plan-edit-event recording for `userId` and installs the push
    /// hook, in one call so they can never be out of sync. Call once the
    /// initial pull has landed (see `CloudSyncCoordinator.start`), so a
    /// mutation made right after sign-in is never silently unrecorded.
    ///
    /// Discards any pending events left over from a *different* account
    /// (EV9): without this, a stale event recorded under account A — still
    /// sitting in `pendingEditEvents` because its push kept failing — would
    /// otherwise get swept up in account B's next push. `CloudMapper` stamps
    /// every pushed row with the *current* signed-in user, so that event
    /// would be silently mis-attributed to B rather than merely rejected.
    func armCloudSync(userId: String, onChange: @escaping @Sendable () -> Void) {
        self.armedUserId = userId
        self.onChange = onChange
        state.pendingEditEvents.removeAll { $0.userId != userId }
    }

    func disarmCloudSync() {
        armedUserId = nil
        onChange = nil
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if let data = try? Data(contentsOf: self.fileURL),
           let loaded = try? decoder.decode(LocalAppState.self, from: data) {
            self.state = loaded
        } else {
            let seeded = Self.makeSeedState()
            self.state = seeded
            try? Self.ensureParentDirectoryExists(for: self.fileURL)
            if let data = try? encoder.encode(seeded) {
                try? data.write(to: self.fileURL, options: [.atomic])
            }
        }
    }

    func fetchProfile() -> UserProfile {
        state.profile
    }

    func updatePreferences(_ prefs: UpdatePreferencesRequest) throws -> UserPreferences {
        if let value = prefs.notificationsEnabled {
            state.profile.preferences.notificationsEnabled = value
        }
        if let value = prefs.darkModeEnabled {
            state.profile.preferences.darkModeEnabled = value
        }
        if let value = prefs.weightUnit {
            state.profile.preferences.weightUnit = value
        }
        if let value = prefs.timezone {
            state.profile.preferences.timezone = value
        }
        if let value = prefs.language {
            state.profile.preferences.language = value
        }

        try persist()
        return state.profile.preferences
    }

    func updateFitnessGoalSummary(_ summary: String) throws -> String {
        let before = state.profile.fitnessGoalSummary
        state.profile.fitnessGoalSummary = summary
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.activePlan = rebuildPlan(
                from: state.activePlan,
                goalSummary: summary,
                coachSummary: state.activePlan.coachSummary
            )
        }
        appendEditEvent(
            type: .goalChanged,
            payload: .from(GoalTextChangedPayload(before: before, after: summary))
        )
        try persist()
        return summary
    }

    func goalSpec() -> GoalSpec? {
        state.goalSpec
    }

    /// Saves the structured goal. Deliberately does not touch `activePlan` —
    /// unlike `updateFitnessGoalSummary`'s legacy free-text path, changing the
    /// goal mid-week must not rebuild the current plan (G4); the next
    /// Phase-2 generation picks it up naturally.
    func updateGoalSpec(_ spec: GoalSpec) throws -> GoalSpec {
        let before = state.goalSpec
        state.goalSpec = spec
        appendEditEvent(
            type: .goalChanged,
            payload: .from(GoalSpecChangedPayload(before: before, after: spec))
        )
        try persist()
        return spec
    }

    func customExercises() -> [ExerciseDefinition] {
        state.customExercises
    }

    func addCustomExercise(
        name: String,
        muscleGroup: MuscleGroup,
        loadType: ExerciseLoadType
    ) throws -> ExerciseDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAppDatabaseError.invalidCustomExerciseName
        }

        if let existing = state.customExercises.first(where: {
            ExerciseDefinition.normalize($0.nameEN) == ExerciseDefinition.normalize(trimmed)
                || ExerciseDefinition.normalize($0.nameZH) == ExerciseDefinition.normalize(trimmed)
        }) {
            return existing
        }

        let definition = ExerciseDefinition(
            id: "custom-\(UUID().uuidString.lowercased())",
            nameEN: trimmed,
            nameZH: trimmed,
            aliases: [],
            muscleGroup: muscleGroup,
            equipment: loadType == .bodyweight ? .bodyweight : .other,
            loadType: loadType,
            popularity: 0,
            isCustom: true
        )
        state.customExercises.append(definition)
        try persist()
        return definition
    }

    func activePlan() -> TrainingPlan? {
        state.activePlan
    }

    func todayPlan() -> TrainingPlanDay? {
        state.activePlan.days.first(where: { $0.planDate == Self.planDateString(from: Date()) })
    }

    func activeDaysInMonth(year: Int, month: Int) -> [Date] {
        let calendar = Calendar.current
        let days = state.strengthSessions.map(\.date) + state.runningRecords.map(\.workoutDate)
        return Array(Set(days.map { calendar.startOfDay(for: $0) })).filter {
            calendar.component(.year, from: $0) == year && calendar.component(.month, from: $0) == month
        }
    }

    func allStrengthSessions() -> [WorkoutSession] {
        state.strengthSessions
    }

    func sessionsForDay(_ date: Date) -> [WorkoutSession] {
        let calendar = Calendar.current
        return state.strengthSessions
            .filter { calendar.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func runningRecordsForDay(_ date: Date) -> [RunningWorkoutRecord] {
        let calendar = Calendar.current
        return state.runningRecords
            .filter { calendar.isDate($0.workoutDate, inSameDayAs: date) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) throws -> RunningWorkoutRecord {
        let now = Date()
        let record = RunningWorkoutRecord(
            id: UUID().uuidString,
            userId: state.profile.id,
            workoutDate: workoutDate,
            durationMinutes: durationMinutes,
            distanceKm: distanceKm,
            source: source,
            createdAt: now,
            updatedAt: now
        )
        state.runningRecords.append(record)
        recalculateDerivedProfile()
        try persist()
        return record
    }

    func createStrengthSession(_ draft: StrengthSessionDraft) throws -> WorkoutSession {
        let now = Date()
        let session = WorkoutSession(
            id: UUID().uuidString,
            userId: state.profile.id,
            date: draft.workoutDate,
            durationMinutes: nil,
            label: draft.title,
            exercises: draft.exercises.enumerated().map { exerciseOffset, exercise in
                Exercise(
                    id: UUID().uuidString,
                    name: exercise.name,
                    exerciseId: exercise.exerciseId,
                    exerciseLoadType: exercise.exerciseLoadType,
                    sets: exercise.sets.enumerated().map { setOffset, set in
                        ExerciseSet(
                            id: UUID().uuidString,
                            setIndex: setOffset + 1,
                            weight: set.weight,
                            weightUnit: set.weightUnit,
                            reps: set.reps,
                            rpe: set.rpe
                        )
                    }
                )
            },
            createdAt: now,
            updatedAt: now
        )
        state.strengthSessions.append(session)
        recalculateDerivedProfile()
        try persist()
        return session
    }

    func updateSet(
        sessionId: String,
        exerciseId: String,
        setId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) throws -> ExerciseSet {
        guard let (sessionIndex, exerciseIndex, setIndex) = findSetIndices(sessionId: sessionId, exerciseId: exerciseId, setId: setId) else {
            throw LocalAppDatabaseError.setNotFound
        }

        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex].weight = weight
        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex].weightUnit = weightUnit
        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex].reps = reps
        state.strengthSessions[sessionIndex].updatedAt = Date()
        recalculateDerivedProfile()
        try persist()
        return state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex]
    }

    func addSet(
        sessionId: String,
        exerciseId: String,
        weight: Double?,
        weightUnit: WeightUnit,
        reps: Int
    ) throws -> ExerciseSet {
        guard let sessionIndex = state.strengthSessions.firstIndex(where: { $0.id == sessionId }) else {
            throw LocalAppDatabaseError.sessionNotFound
        }
        guard let exerciseIndex = state.strengthSessions[sessionIndex].exercises.firstIndex(where: { $0.id == exerciseId }) else {
            throw LocalAppDatabaseError.exerciseNotFound
        }

        let nextIndex = (state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.map(\.setIndex).max() ?? 0) + 1
        let newSet = ExerciseSet(
            id: UUID().uuidString,
            setIndex: nextIndex,
            weight: weight,
            weightUnit: weightUnit,
            reps: reps,
            rpe: nil
        )
        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.append(newSet)
        state.strengthSessions[sessionIndex].updatedAt = Date()
        recalculateDerivedProfile()
        try persist()
        return newSet
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) throws {
        guard let (sessionIndex, exerciseIndex, setIndex) = findSetIndices(sessionId: sessionId, exerciseId: exerciseId, setId: setId) else {
            throw LocalAppDatabaseError.setNotFound
        }

        state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.remove(at: setIndex)
        normalizeSetIndices(for: sessionIndex, exerciseIndex: exerciseIndex)
        state.strengthSessions[sessionIndex].updatedAt = Date()
        recalculateDerivedProfile()
        try persist()
    }

    func updateSetRPE(setId: String, rpe: Double?) throws -> ExerciseSet {
        for sessionIndex in state.strengthSessions.indices {
            for exerciseIndex in state.strengthSessions[sessionIndex].exercises.indices {
                if let setIndex = state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) {
                    state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex].rpe = rpe
                    state.strengthSessions[sessionIndex].updatedAt = Date()
                    try persist()
                    return state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[setIndex]
                }
            }
        }
        throw LocalAppDatabaseError.setNotFound
    }

    func completePlannedSet(
        planSetId: String,
        actualWeight: Double?,
        actualWeightUnit: WeightUnit,
        actualReps: Int
    ) throws -> TrainingPlanSet {
        guard let planLocation = findPlanSet(planSetId: planSetId) else {
            throw LocalAppDatabaseError.planSetNotFound
        }

        let now = Date()
        var day = state.activePlan.days[planLocation.dayIndex]
        let exercise = day.exercises[planLocation.exerciseIndex]

        let linkedSet = ExerciseSet(
            id: UUID().uuidString,
            setIndex: actualSetIndex(for: day.id, exerciseName: exercise.exerciseName),
            weight: actualWeight,
            weightUnit: actualWeightUnit,
            reps: actualReps,
            rpe: nil
        )

        let sessionId = ensureStrengthSessionForPlanDay(
            day,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            exerciseLoadType: exercise.exerciseLoadType,
            linkedSet: linkedSet
        )
        day.exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].completedAt = now
        day.exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].linkedExerciseSetId = linkedSet.id
        state.activePlan.days[planLocation.dayIndex] = day

        recalculateDerivedProfile()
        try persist()

        var result = state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex]
        result.linkedExerciseSetId = linkedSet.id
        _ = sessionId
        return result
    }

    func updatePlannedSet(
        planSetId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) throws -> TrainingPlanSet {
        guard let planLocation = findPlanSet(planSetId: planSetId) else {
            throw LocalAppDatabaseError.planSetNotFound
        }
        let day = state.activePlan.days[planLocation.dayIndex]
        let exercise = day.exercises[planLocation.exerciseIndex]
        let before = PlannedSetSnapshot(exercise.sets[planLocation.setIndex])

        state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].targetWeight = targetWeight
        state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].targetWeightUnit = targetWeightUnit
        state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex].targetReps = targetReps

        let updated = state.activePlan.days[planLocation.dayIndex].exercises[planLocation.exerciseIndex].sets[planLocation.setIndex]
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day.id,
            planDate: day.planDate,
            type: .setTargetUpdated,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            payload: .from(SetTargetUpdatedPayload(before: before, after: PlannedSetSnapshot(updated)))
        )
        try persist()
        return updated
    }

    func addPlannedSet(
        planExerciseId: String,
        targetWeight: Double?,
        targetWeightUnit: WeightUnit,
        targetReps: Int
    ) throws -> TrainingPlanSet {
        guard let location = findPlanExercise(planExerciseId: planExerciseId) else {
            throw LocalAppDatabaseError.planExerciseNotFound
        }
        let day = state.activePlan.days[location.dayIndex]
        let exercise = day.exercises[location.exerciseIndex]
        let nextIndex = (exercise.sets.map(\.setIndex).max() ?? 0) + 1
        let set = TrainingPlanSet(
            id: UUID().uuidString,
            setIndex: nextIndex,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
        state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex].sets.append(set)
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day.id,
            planDate: day.planDate,
            type: .setAdded,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            payload: .from(PlannedSetSnapshot(set))
        )
        try persist()
        return set
    }

    func deletePlannedSet(planSetId: String) throws {
        guard let location = findPlanSet(planSetId: planSetId) else {
            throw LocalAppDatabaseError.planSetNotFound
        }
        let day = state.activePlan.days[location.dayIndex]
        let exercise = day.exercises[location.exerciseIndex]
        let removedSet = exercise.sets[location.setIndex]

        state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex].sets.remove(at: location.setIndex)
        for index in state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex].sets.indices {
            state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex].sets[index].setIndex = index + 1
        }
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day.id,
            planDate: day.planDate,
            type: .setRemoved,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            payload: .from(SetRemovedPayload(snapshot: PlannedSetSnapshot(removedSet), wasCompleted: removedSet.isCompleted))
        )
        try persist()
    }

    func deletePlannedExercise(planExerciseId: String) throws {
        guard let location = findPlanExercise(planExerciseId: planExerciseId) else {
            throw LocalAppDatabaseError.planExerciseNotFound
        }

        let day = state.activePlan.days[location.dayIndex]
        // 已完成组落库产生的训练记录一并删除，避免计划删掉后留下孤儿记录。
        let exercise = state.activePlan.days[location.dayIndex].exercises[location.exerciseIndex]
        removeLoggedSets(withIds: Set(exercise.sets.compactMap(\.linkedExerciseSetId)))

        state.activePlan.days[location.dayIndex].exercises.remove(at: location.exerciseIndex)
        for index in state.activePlan.days[location.dayIndex].exercises.indices {
            state.activePlan.days[location.dayIndex].exercises[index].orderIndex = index
        }
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: day.id,
            planDate: day.planDate,
            type: .exerciseRemoved,
            exerciseName: exercise.exerciseName,
            exerciseId: exercise.exerciseId,
            payload: .from(ExerciseRemovedPayload(
                snapshot: PlannedExerciseSnapshot(exercise),
                hadCompletedSets: exercise.sets.contains(where: \.isCompleted)
            ))
        )
        recalculateDerivedProfile()
        try persist()
    }

    func deleteExercise(sessionId: String, exerciseId: String) throws {
        // 今日记录是多个 session 合并展示的，exerciseId 不一定挂在传入的 session 下，找不到时退回全量查找。
        let sessionIndex = state.strengthSessions.firstIndex {
            $0.id == sessionId && $0.exercises.contains { $0.id == exerciseId }
        } ?? state.strengthSessions.firstIndex { $0.exercises.contains { $0.id == exerciseId } }
        guard let sessionIndex,
              let exerciseIndex = state.strengthSessions[sessionIndex].exercises.firstIndex(where: { $0.id == exerciseId })
        else {
            throw LocalAppDatabaseError.exerciseNotFound
        }

        let removedSetIds = Set(state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.map(\.id))
        state.strengthSessions[sessionIndex].exercises.remove(at: exerciseIndex)
        if state.strengthSessions[sessionIndex].exercises.isEmpty {
            state.strengthSessions.remove(at: sessionIndex)
        } else {
            state.strengthSessions[sessionIndex].updatedAt = Date()
        }
        clearPlanCompletionLinks(to: removedSetIds)
        recalculateDerivedProfile()
        try persist()
    }

    /// 删除散落在各 session 中的记录组；清空后的动作与 session 一并移除。
    private func removeLoggedSets(withIds setIds: Set<String>) {
        guard !setIds.isEmpty else { return }
        for sessionIndex in state.strengthSessions.indices {
            var didChange = false
            for exerciseIndex in state.strengthSessions[sessionIndex].exercises.indices {
                let before = state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.count
                state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.removeAll { setIds.contains($0.id) }
                guard state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.count != before else { continue }
                didChange = true
                normalizeSetIndices(for: sessionIndex, exerciseIndex: exerciseIndex)
            }
            if didChange {
                state.strengthSessions[sessionIndex].exercises.removeAll { $0.sets.isEmpty }
                state.strengthSessions[sessionIndex].updatedAt = Date()
            }
        }
        state.strengthSessions.removeAll { $0.exercises.isEmpty }
    }

    /// 记录被删除后，指向这些记录组的计划组回退为未完成。
    private func clearPlanCompletionLinks(to removedSetIds: Set<String>) {
        guard !removedSetIds.isEmpty else { return }
        for dayIndex in state.activePlan.days.indices {
            for exerciseIndex in state.activePlan.days[dayIndex].exercises.indices {
                for setIndex in state.activePlan.days[dayIndex].exercises[exerciseIndex].sets.indices {
                    guard let linkedId = state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex].linkedExerciseSetId,
                          removedSetIds.contains(linkedId) else { continue }
                    state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex].linkedExerciseSetId = nil
                    state.activePlan.days[dayIndex].exercises[exerciseIndex].sets[setIndex].completedAt = nil
                }
            }
        }
    }

    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) throws -> TrainingPlanDay {
        guard !drafts.isEmpty,
              drafts.allSatisfy({ !$0.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LocalAppDatabaseError.invalidPlanExerciseName
        }

        let todayDateString = Self.planDateString(from: Date())

        if let dayIndex = state.activePlan.days.firstIndex(where: { $0.planDate == todayDateString }) {
            var day = state.activePlan.days[dayIndex]
            let wasEmpty = day.exercises.isEmpty
            var addedExercises: [TrainingPlanExercise] = []
            for draft in drafts {
                let exercise = makePlanExercise(from: draft, orderIndex: day.exercises.count)
                day.exercises.append(exercise)
                addedExercises.append(exercise)
            }
            if wasEmpty {
                day = TrainingPlanDay(
                    id: day.id,
                    planDate: day.planDate,
                    dayIndex: day.dayIndex,
                    title: String(localized: "today.plan.manual_day_title"),
                    focus: day.focus,
                    status: "planned",
                    exercises: day.exercises
                )
            }
            state.activePlan.days[dayIndex] = day
            for exercise in addedExercises {
                appendEditEvent(
                    planId: state.activePlan.id,
                    planDayId: day.id,
                    planDate: day.planDate,
                    type: .exerciseAdded,
                    exerciseName: exercise.exerciseName,
                    exerciseId: exercise.exerciseId,
                    payload: .from(PlannedExerciseSnapshot(exercise))
                )
            }
            try persist()
            return day
        }

        let exercises = drafts.enumerated().map { index, draft in
            makePlanExercise(from: draft, orderIndex: index)
        }
        let nextDayIndex = (state.activePlan.days.map(\.dayIndex).max() ?? 0) + 1
        let day = TrainingPlanDay(
            id: UUID().uuidString,
            planDate: todayDateString,
            dayIndex: nextDayIndex,
            title: String(localized: "today.plan.manual_day_title"),
            focus: nil,
            status: "planned",
            exercises: exercises
        )
        state.activePlan.days.append(day)
        for exercise in exercises {
            appendEditEvent(
                planId: state.activePlan.id,
                planDayId: day.id,
                planDate: day.planDate,
                type: .exerciseAdded,
                exerciseName: exercise.exerciseName,
                exerciseId: exercise.exerciseId,
                payload: .from(PlannedExerciseSnapshot(exercise))
            )
        }
        try persist()
        return day
    }

    func reorderPlannedExercises(orderedExerciseIds: [String]) throws -> TrainingPlanDay {
        let todayDateString = Self.planDateString(from: Date())
        guard let dayIndex = state.activePlan.days.firstIndex(where: { $0.planDate == todayDateString }) else {
            throw LocalAppDatabaseError.planExerciseNotFound
        }
        let beforeNames = state.activePlan.days[dayIndex].exercises
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(\.exerciseName)
        guard let reorderedDay = state.activePlan.days[dayIndex].reordered(byExerciseIds: orderedExerciseIds) else {
            throw LocalAppDatabaseError.invalidExerciseOrder
        }
        let afterNames = reorderedDay.exercises
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(\.exerciseName)
        state.activePlan.days[dayIndex] = reorderedDay
        appendEditEvent(
            planId: state.activePlan.id,
            planDayId: reorderedDay.id,
            planDate: reorderedDay.planDate,
            type: .exercisesReordered,
            payload: .from(ExercisesReorderedPayload(before: beforeNames, after: afterNames))
        )
        try persist()
        return reorderedDay
    }

    private func makePlanExercise(from draft: PlanExerciseDraft, orderIndex: Int) -> TrainingPlanExercise {
        TrainingPlanExercise(
            id: UUID().uuidString,
            orderIndex: orderIndex,
            exerciseName: draft.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines),
            exerciseId: draft.exerciseId,
            exerciseLoadType: draft.isBodyweight ? .bodyweight : .weighted,
            progressionMode: "manual",
            notes: nil,
            previousPerformanceSummary: nil,
            aiSuggestion: nil,
            sets: draft.sets.enumerated().map { index, set in
                TrainingPlanSet(
                    id: UUID().uuidString,
                    setIndex: index + 1,
                    targetWeight: set.targetWeight,
                    targetWeightUnit: set.targetWeightUnit,
                    targetReps: set.targetReps,
                    completedAt: nil,
                    linkedExerciseSetId: nil
                )
            }
        )
    }

    private func rebuildPlan(from plan: TrainingPlan, goalSummary: String?, coachSummary: String) -> TrainingPlan {
        TrainingPlan(
            id: plan.id,
            weekStartDate: plan.weekStartDate,
            goalSummary: goalSummary,
            coachSummary: coachSummary,
            days: plan.days
        )
    }

    private func findSetIndices(sessionId: String, exerciseId: String, setId: String) -> (Int, Int, Int)? {
        guard let sessionIndex = state.strengthSessions.firstIndex(where: { $0.id == sessionId }) else {
            return nil
        }
        guard let exerciseIndex = state.strengthSessions[sessionIndex].exercises.firstIndex(where: { $0.id == exerciseId }) else {
            return nil
        }
        guard let setIndex = state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) else {
            return nil
        }
        return (sessionIndex, exerciseIndex, setIndex)
    }

    private func findPlanExercise(planExerciseId: String) -> (dayIndex: Int, exerciseIndex: Int)? {
        for dayIndex in state.activePlan.days.indices {
            if let exerciseIndex = state.activePlan.days[dayIndex].exercises.firstIndex(where: { $0.id == planExerciseId }) {
                return (dayIndex, exerciseIndex)
            }
        }
        return nil
    }

    private func findPlanSet(planSetId: String) -> (dayIndex: Int, exerciseIndex: Int, setIndex: Int)? {
        for dayIndex in state.activePlan.days.indices {
            for exerciseIndex in state.activePlan.days[dayIndex].exercises.indices {
                if let setIndex = state.activePlan.days[dayIndex].exercises[exerciseIndex].sets.firstIndex(where: { $0.id == planSetId }) {
                    return (dayIndex, exerciseIndex, setIndex)
                }
            }
        }
        return nil
    }

    private func ensureStrengthSessionForPlanDay(
        _ day: TrainingPlanDay,
        exerciseName: String,
        exerciseId: String?,
        exerciseLoadType: ExerciseLoadType,
        linkedSet: ExerciseSet
    ) -> String {
        let sessionDate = Self.date(from: day.planDate) ?? Date()
        let calendar = Calendar.current

        if let sessionIndex = state.strengthSessions.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: sessionDate) }) {
            if let exerciseIndex = state.strengthSessions[sessionIndex].exercises.firstIndex(where: {
                $0.name.localizedCaseInsensitiveCompare(exerciseName) == .orderedSame
            }) {
                state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.append(linkedSet)
            } else {
                state.strengthSessions[sessionIndex].exercises.append(
                    Exercise(id: UUID().uuidString, name: exerciseName, exerciseId: exerciseId, exerciseLoadType: exerciseLoadType, sets: [linkedSet])
                )
            }
            state.strengthSessions[sessionIndex].updatedAt = Date()
            return state.strengthSessions[sessionIndex].id
        }

        let now = Date()
        let session = WorkoutSession(
            id: UUID().uuidString,
            userId: state.profile.id,
            date: sessionDate,
            durationMinutes: nil,
            label: day.title,
            exercises: [Exercise(id: UUID().uuidString, name: exerciseName, exerciseId: exerciseId, exerciseLoadType: exerciseLoadType, sets: [linkedSet])],
            createdAt: now,
            updatedAt: now
        )
        state.strengthSessions.append(session)
        return session.id
    }

    private func actualSetIndex(for planDayId: String, exerciseName: String) -> Int {
        let planDay = state.activePlan.days.first(where: { $0.id == planDayId })
        let date = planDay.flatMap { Self.date(from: $0.planDate) } ?? Date()
        let calendar = Calendar.current

        guard let session = state.strengthSessions.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else {
            return 1
        }
        return (session.exercises.first(where: { $0.name.localizedCaseInsensitiveCompare(exerciseName) == .orderedSame })?.sets.count ?? 0) + 1
    }

    private func normalizeSetIndices(for sessionIndex: Int, exerciseIndex: Int) {
        for index in state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets.indices {
            state.strengthSessions[sessionIndex].exercises[exerciseIndex].sets[index].setIndex = index + 1
        }
    }

    private func recalculateDerivedProfile() {
        let calendar = Calendar.current
        let activeDays = Array(Set((state.strengthSessions.map(\.date) + state.runningRecords.map(\.workoutDate)).map { calendar.startOfDay(for: $0) })).sorted()

        var streak = 0
        var cursor = calendar.startOfDay(for: Date())
        let activeDaySet = Set(activeDays)
        while activeDaySet.contains(cursor) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }

        let totalVolume = state.strengthSessions.reduce(0.0) { partialResult, session in
            partialResult + session.exercises.flatMap(\.sets).reduce(0.0) { subtotal, set in
                subtotal + ((set.weight ?? 0) * Double(set.reps))
            }
        }

        var prsByExercise: [String: ExercisePR] = [:]
        for session in state.strengthSessions {
            for exercise in session.exercises {
                let normalizedName = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let maxSet = exercise.sets.compactMap({ set -> (Double, WeightUnit)? in
                    guard let weight = set.weight else { return nil }
                    return (weight, set.weightUnit)
                }).max(by: { $0.0 < $1.0 }) else {
                    continue
                }

                let candidate = ExercisePR(
                    normalizedName: normalizedName,
                    displayName: exercise.name,
                    maxWeight: maxSet.0,
                    weightUnit: maxSet.1,
                    achievedAt: session.date
                )

                if let existing = prsByExercise[normalizedName], existing.maxWeight >= candidate.maxWeight {
                    continue
                }
                prsByExercise[normalizedName] = candidate
            }
        }

        state.profile.exercisePRs = prsByExercise.values.sorted { $0.maxWeight > $1.maxWeight }
        state.profile.stats = UserStats(
            workoutsCount: state.strengthSessions.count + state.runningRecords.count,
            streakDays: streak,
            totalVolumeKg: totalVolume,
            prCount: state.profile.exercisePRs.count
        )
    }

    // MARK: - Plan edit events

    private struct PlannedSetSnapshot: Encodable {
        let setIndex: Int
        let targetWeight: Double?
        let targetWeightUnit: WeightUnit
        let targetReps: Int

        init(_ set: TrainingPlanSet) {
            setIndex = set.setIndex
            targetWeight = set.targetWeight
            targetWeightUnit = set.targetWeightUnit
            targetReps = set.targetReps
        }
    }

    private struct PlannedExerciseSnapshot: Encodable {
        let exerciseName: String
        let exerciseId: String?
        let exerciseLoadType: ExerciseLoadType
        let sets: [PlannedSetSnapshot]

        init(_ exercise: TrainingPlanExercise) {
            exerciseName = exercise.exerciseName
            exerciseId = exercise.exerciseId
            exerciseLoadType = exercise.exerciseLoadType
            sets = exercise.sets.map(PlannedSetSnapshot.init)
        }
    }

    private struct ExerciseRemovedPayload: Encodable {
        let snapshot: PlannedExerciseSnapshot
        let hadCompletedSets: Bool
    }

    private struct SetRemovedPayload: Encodable {
        let snapshot: PlannedSetSnapshot
        let wasCompleted: Bool
    }

    private struct SetTargetUpdatedPayload: Encodable {
        let before: PlannedSetSnapshot
        let after: PlannedSetSnapshot
    }

    private struct ExercisesReorderedPayload: Encodable {
        let before: [String]
        let after: [String]
    }

    private struct GoalTextChangedPayload: Encodable {
        let before: String?
        let after: String
    }

    private struct GoalSpecChangedPayload: Encodable {
        let before: GoalSpec?
        let after: GoalSpec
    }

    /// Records a structural plan edit. No-op while unarmed (signed out or
    /// DEBUG local mode, EV8) so the outbox never accumulates events nobody
    /// will push. Caps at `maxPendingEditEvents`, dropping the oldest — a
    /// bound against unbounded growth if pushing stays broken for a long
    /// time (EV12), not a limit normal usage should ever reach.
    private func appendEditEvent(
        planId: String? = nil,
        planDayId: String? = nil,
        planDate: String? = nil,
        type: PlanEditEventType,
        exerciseName: String? = nil,
        exerciseId: String? = nil,
        payload: JSONValue
    ) {
        guard let userId = armedUserId else { return }
        state.editEventSeq += 1
        let event = PlanEditEvent(
            id: UUID().uuidString,
            userId: userId,
            planId: planId,
            planDayId: planDayId,
            planDate: planDate,
            eventType: type,
            exerciseName: exerciseName,
            exerciseId: exerciseId,
            payload: payload,
            source: .user,
            clientSeq: state.editEventSeq,
            occurredAt: Date()
        )
        state.pendingEditEvents.append(event)
        let overflow = state.pendingEditEvents.count - Self.maxPendingEditEvents
        if overflow > 0 {
            state.pendingEditEvents.removeFirst(overflow)
            droppedEditEventCount += overflow
        }
    }

    /// Drops events the cloud has confirmed receiving. Safe to call with ids
    /// that no longer exist locally (already cleared by a later call).
    func clearPushedEditEvents(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        state.pendingEditEvents.removeAll { ids.contains($0.id) }
    }

    private func persist() throws {
        try writeStateToDisk()
        onChange?()
    }

    private func writeStateToDisk() throws {
        try Self.ensureParentDirectoryExists(for: fileURL)
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    // MARK: - Cloud sync bridge

    /// A copy of everything the cloud syncer needs to reconcile. Reads are cheap
    /// (value types), so callers snapshot rather than hold the actor.
    func snapshot() -> LocalDataSnapshot {
        LocalDataSnapshot(
            profile: state.profile,
            activePlan: state.activePlan,
            strengthSessions: state.strengthSessions,
            runningRecords: state.runningRecords,
            customExercises: state.customExercises,
            goalSpec: state.goalSpec,
            pendingEditEvents: state.pendingEditEvents
        )
    }

    /// Replace the entire cache with cloud truth (a pull). Does not fire
    /// `onChange`: this is the sync writing in, not the user mutating.
    /// Derived profile fields (stats, PRs) are recomputed from the pulled
    /// sessions so the UI matches without a separate stats fetch.
    ///
    /// `pendingEditEvents`/`editEventSeq` are deliberately NOT touched here —
    /// a pull overwrites cloud-mirrored *state*, but those are unpushed
    /// *facts* that must survive it (EV1). `goalSpec` is ordinary state, so
    /// it IS overwritten like everything else, cloud-wins.
    func replaceAll(
        profile: UserProfile,
        activePlan: TrainingPlan,
        strengthSessions: [WorkoutSession],
        runningRecords: [RunningWorkoutRecord],
        customExercises: [ExerciseDefinition],
        goalSpec: GoalSpec?
    ) {
        state.profile = profile
        state.activePlan = activePlan
        state.strengthSessions = strengthSessions
        state.runningRecords = runningRecords
        state.customExercises = customExercises
        state.goalSpec = goalSpec
        recalculateDerivedProfile()
        try? writeStateToDisk()
    }

    private static func ensureParentDirectoryExists(for fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("PeakLog/peaklog-local-state.json")
    }

    private static func makeSeedState() -> LocalAppState {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today

        let plan = TrainingPlan(
            id: "local-plan",
            weekStartDate: planDateString(from: weekStart),
            goalSummary: "Build muscle with extra focus on upper body strength and consistent weekly progress.",
            coachSummary: "4 training days this week. Keep one hard lower-body day and one lighter conditioning day.",
            days: (0..<7).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? today
                let isToday = calendar.isDate(date, inSameDayAs: today)
                return TrainingPlanDay(
                    id: "plan-day-\(offset + 1)",
                    planDate: planDateString(from: date),
                    dayIndex: offset + 1,
                    title: isToday ? "Today's Strength Session" : sampleDayTitle(for: offset),
                    focus: sampleDayFocus(for: offset),
                    status: isToday ? "planned" : "upcoming",
                    exercises: samplePlanExercises(for: offset)
                )
            }
        )

        let yesterdaySession = WorkoutSession(
            id: "seed-session-1",
            userId: "local-user",
            date: yesterday,
            durationMinutes: 45,
            label: "Pull Day",
            exercises: [
                Exercise(
                    id: "seed-exercise-1",
                    name: "Deadlift",
                    sets: [
                        ExerciseSet(id: "seed-set-1", setIndex: 1, weight: 120, weightUnit: .kg, reps: 5, rpe: nil),
                        ExerciseSet(id: "seed-set-2", setIndex: 2, weight: 120, weightUnit: .kg, reps: 5, rpe: nil)
                    ]
                ),
                Exercise(
                    id: "seed-exercise-2",
                    name: "Pull Up",
                    sets: [
                        ExerciseSet(id: "seed-set-3", setIndex: 1, weight: nil, weightUnit: .kg, reps: 10, rpe: nil),
                        ExerciseSet(id: "seed-set-4", setIndex: 2, weight: nil, weightUnit: .kg, reps: 9, rpe: nil)
                    ]
                )
            ],
            createdAt: yesterday.addingTimeInterval(9 * 3600),
            updatedAt: yesterday.addingTimeInterval(9 * 3600)
        )

        let seedRun = RunningWorkoutRecord(
            id: "seed-run-1",
            userId: "local-user",
            workoutDate: calendar.date(byAdding: .day, value: -2, to: today) ?? today,
            durationMinutes: 28,
            distanceKm: 5.2,
            source: .manual,
            createdAt: yesterday,
            updatedAt: yesterday
        )

        var state = LocalAppState(
            profile: UserProfile(
                id: "local-user",
                displayName: "PeakLog Athlete",
                avatarURL: nil,
                membershipLevel: .premium,
                stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: 0, prCount: 0),
                preferences: UserPreferences(
                    notificationsEnabled: true,
                    darkModeEnabled: true,
                    weightUnit: .kg,
                    timezone: TimeZone.current.identifier,
                    language: .english
                ),
                fitnessGoalSummary: "Build muscle with extra focus on upper body strength and consistent weekly progress.",
                exercisePRs: []
            ),
            activePlan: plan,
            strengthSessions: [yesterdaySession],
            runningRecords: [seedRun]
        )

        let db = LocalAppDatabasePreviewDriver(state: state)
        state.profile.stats = db.stats
        state.profile.exercisePRs = db.exercisePRs
        return state
    }

    private static func samplePlanExercises(for offset: Int) -> [TrainingPlanExercise] {
        switch offset {
        case 0:
            return [
                TrainingPlanExercise(
                    id: "plan-ex-1",
                    orderIndex: 0,
                    exerciseName: "Bench Press",
                    exerciseLoadType: .weighted,
                    progressionMode: "weight_first",
                    notes: "Stop 1 rep before failure on the first two sets.",
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(id: "plan-set-1", setIndex: 1, targetWeight: 60, targetWeightUnit: .kg, targetReps: 8, completedAt: nil, linkedExerciseSetId: nil),
                        TrainingPlanSet(id: "plan-set-2", setIndex: 2, targetWeight: 60, targetWeightUnit: .kg, targetReps: 8, completedAt: nil, linkedExerciseSetId: nil),
                        TrainingPlanSet(id: "plan-set-3", setIndex: 3, targetWeight: 62.5, targetWeightUnit: .kg, targetReps: 6, completedAt: nil, linkedExerciseSetId: nil)
                    ]
                )
            ]
        case 2:
            return [
                TrainingPlanExercise(
                    id: "plan-ex-2",
                    orderIndex: 0,
                    exerciseName: "Squat",
                    exerciseLoadType: .weighted,
                    progressionMode: "volume_first",
                    notes: "Focus on full depth and steady tempo.",
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(id: "plan-set-4", setIndex: 1, targetWeight: 90, targetWeightUnit: .kg, targetReps: 6, completedAt: nil, linkedExerciseSetId: nil),
                        TrainingPlanSet(id: "plan-set-5", setIndex: 2, targetWeight: 90, targetWeightUnit: .kg, targetReps: 6, completedAt: nil, linkedExerciseSetId: nil)
                    ]
                )
            ]
        case 4:
            return [
                TrainingPlanExercise(
                    id: "plan-ex-3",
                    orderIndex: 0,
                    exerciseName: "Pull Up",
                    exerciseLoadType: .bodyweight,
                    progressionMode: "rep_first",
                    notes: "Add a pause at the top of each rep.",
                    previousPerformanceSummary: nil,
                    aiSuggestion: nil,
                    sets: [
                        TrainingPlanSet(id: "plan-set-6", setIndex: 1, targetWeight: nil, targetWeightUnit: .kg, targetReps: 10, completedAt: nil, linkedExerciseSetId: nil),
                        TrainingPlanSet(id: "plan-set-7", setIndex: 2, targetWeight: nil, targetWeightUnit: .kg, targetReps: 10, completedAt: nil, linkedExerciseSetId: nil)
                    ]
                )
            ]
        default:
            return []
        }
    }

    private static func sampleDayTitle(for offset: Int) -> String {
        switch offset {
        case 1: return "Recovery + Zone 2"
        case 2: return "Lower Strength"
        case 3: return "Mobility"
        case 4: return "Upper Pull"
        case 5: return "Conditioning"
        default: return "Rest"
        }
    }

    private static func sampleDayFocus(for offset: Int) -> String? {
        switch offset {
        case 0: return "Pressing strength"
        case 1: return "Easy aerobic work"
        case 2: return "Leg drive and bracing"
        case 4: return "Back volume and grip"
        case 5: return "Light conditioning"
        default: return nil
        }
    }

    private static func planDateString(from date: Date) -> String {
        let formatter = WorkoutDateFormatter()
        return formatter.string(from: date)
    }

    private static func timestampString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(from planDate: String) -> Date? {
        WorkoutDateFormatter().date(from: planDate)
    }
}

enum LocalAppDatabaseError: LocalizedError {
    case sessionNotFound
    case exerciseNotFound
    case setNotFound
    case planExerciseNotFound
    case planSetNotFound
    case invalidPlanExerciseName
    case invalidCustomExerciseName
    case invalidExerciseOrder

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Workout session not found."
        case .exerciseNotFound:
            return "Exercise not found."
        case .setNotFound:
            return "Set not found."
        case .planExerciseNotFound:
            return "Planned exercise not found."
        case .planSetNotFound:
            return "Planned set not found."
        case .invalidPlanExerciseName:
            return "Exercise name cannot be empty."
        case .invalidCustomExerciseName:
            return "Custom exercise name cannot be empty."
        case .invalidExerciseOrder:
            return "Exercise order is invalid."
        }
    }
}

nonisolated private struct LocalAppDatabasePreviewDriver: Sendable {
    let stats: UserStats
    let exercisePRs: [ExercisePR]

    init(state: LocalAppState) {
        let calendar = Calendar.current
        let activeDays = Array(Set((state.strengthSessions.map(\.date) + state.runningRecords.map(\.workoutDate)).map { calendar.startOfDay(for: $0) })).sorted()
        let totalVolume = state.strengthSessions.reduce(0.0) { partialResult, session in
            partialResult + session.exercises.flatMap(\.sets).reduce(0.0) { subtotal, set in
                subtotal + ((set.weight ?? 0) * Double(set.reps))
            }
        }

        var prsByExercise: [String: ExercisePR] = [:]
        for session in state.strengthSessions {
            for exercise in session.exercises {
                let normalizedName = exercise.name.lowercased()
                guard let maxSet = exercise.sets.compactMap({ set -> (Double, WeightUnit)? in
                    guard let weight = set.weight else { return nil }
                    return (weight, set.weightUnit)
                }).max(by: { $0.0 < $1.0 }) else {
                    continue
                }
                prsByExercise[normalizedName] = ExercisePR(
                    normalizedName: normalizedName,
                    displayName: exercise.name,
                    maxWeight: maxSet.0,
                    weightUnit: maxSet.1,
                    achievedAt: session.date
                )
            }
        }

        let streak = activeDays.contains(calendar.startOfDay(for: Date())) ? 1 : 0
        self.stats = UserStats(
            workoutsCount: state.strengthSessions.count + state.runningRecords.count,
            streakDays: streak,
            totalVolumeKg: totalVolume,
            prCount: prsByExercise.count
        )
        self.exercisePRs = prsByExercise.values.sorted { $0.maxWeight > $1.maxWeight }
    }
}

enum AppServices {
    static let database = LocalAppDatabase.shared
    static let profileService: ProfileServiceProtocol = LocalProfileService(database: database)
    static let workoutService: WorkoutServiceProtocol = LocalWorkoutService(database: database)
    static let trainingPlanService: TrainingPlanServiceProtocol = LocalTrainingPlanService(database: database)
    static let exerciseLibraryService: ExerciseLibraryServiceProtocol = LocalExerciseLibraryService(database: database)
    static let setDefaultsProvider: SetDefaultsProviding = RuleBasedSetDefaultsProvider(
        exerciseLibraryService: exerciseLibraryService,
        profileService: profileService
    )
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
