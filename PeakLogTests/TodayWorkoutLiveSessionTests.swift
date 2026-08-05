import XCTest
@testable import PeakLog

@MainActor
final class TodayWorkoutLiveSessionTests: XCTestCase {
    func testConfirmingLivePlanSessionPersistsCompletedSetsIntoTodayRecord() async {
        let trainingPlanService = LiveSessionTrainingPlanService()
        let workoutService = LiveSessionWorkoutService()
        let liveActivityManager = LiveSessionActivityManager()
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: trainingPlanService,
            workoutService: workoutService,
            liveActivityManager: liveActivityManager
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        viewModel.completeCurrentLiveSet()
        viewModel.completeCurrentLiveSet()
        await viewModel.confirmPlanLiveWorkout()

        XCTAssertNil(viewModel.activeLiveWorkout)
        XCTAssertEqual(trainingPlanService.completedPlanSetIds, ["plan-set-1", "plan-set-2"])
        XCTAssertEqual(viewModel.todayRecord?.exercises.first?.sets.count, 2)
        XCTAssertEqual(liveActivityManager.startedSessionIds.count, 1)
        XCTAssertEqual(liveActivityManager.didEndCount, 1)
    }

    func testFinishingASessionPublishesASummaryAndPresentsIt() async throws {
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager(),
            profileService: LiveSessionProfileService()
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        viewModel.completeCurrentLiveSet()
        viewModel.completeCurrentLiveSet()
        await viewModel.confirmPlanLiveWorkout()

        XCTAssertTrue(viewModel.isPresentingSessionSummary)
        let summary = try XCTUnwrap(viewModel.sessionSummary)
        XCTAssertEqual(summary.completedSets, 2)
        XCTAssertEqual(summary.totalSets, 2)
        // 2 sets × 60kg × 8 reps
        XCTAssertEqual(summary.totalVolumeKg, 960)
        XCTAssertNotNil(summary.durationSeconds, "startedAt is stamped when the session begins")
    }

    /// The PR baseline has to be read *before* this workout is written, or the
    /// freshly-saved sets become their own baseline and nothing ever reads as a PR.
    func testNewRecordIsDetectedAgainstThePreWorkoutBaseline() async {
        let profileService = LiveSessionProfileService(prWeightKg: 50)
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager(),
            profileService: profileService
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        viewModel.completeCurrentLiveSet()
        await viewModel.confirmPlanLiveWorkout()

        // Planned sets are 60kg, above the 50kg baseline.
        XCTAssertEqual(viewModel.sessionSummary?.newRecordCount, 1)
    }

    func testWorkoutBelowExistingRecordReportsNoPR() async {
        let profileService = LiveSessionProfileService(prWeightKg: 100)
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager(),
            profileService: profileService
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        viewModel.completeCurrentLiveSet()
        await viewModel.confirmPlanLiveWorkout()

        XCTAssertEqual(viewModel.sessionSummary?.newRecordCount, 0)
    }

    /// Cancelling is not finishing: no summary, nothing presented.
    func testCancellingASessionPublishesNoSummary() async {
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager(),
            profileService: LiveSessionProfileService()
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        viewModel.completeCurrentLiveSet()
        viewModel.cancelPlanLiveWorkout()

        XCTAssertNil(viewModel.sessionSummary)
        XCTAssertFalse(viewModel.isPresentingSessionSummary)
    }

    /// Finishing without a single completed set has nothing to summarize.
    func testFinishingWithNoCompletedSetsPublishesNoSummary() async {
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager(),
            profileService: LiveSessionProfileService()
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        await viewModel.confirmPlanLiveWorkout()

        XCTAssertNil(viewModel.sessionSummary)
        XCTAssertFalse(viewModel.isPresentingSessionSummary)
    }

    /// Rest is a window, not just an end time — the panel's progress bar needs
    /// both ends, and "+30s" must move only the end.
    func testRestWindowIsExposedAndExtendable() async throws {
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager()
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        viewModel.completeCurrentLiveSet()

        let start = try XCTUnwrap(viewModel.restStartDate)
        let end = try XCTUnwrap(viewModel.restEndDate)
        XCTAssertEqual(
            end.timeIntervalSince(start),
            TodayWorkoutViewModel.restDurationSeconds,
            accuracy: 0.5
        )

        viewModel.extendRest(by: 30)
        let extended = try XCTUnwrap(viewModel.restEndDate)
        XCTAssertEqual(extended.timeIntervalSince(end), 30, accuracy: 0.001)
        XCTAssertEqual(viewModel.restStartDate, start, "Extending must not move the window's start")

        viewModel.skipRest()
        XCTAssertNil(viewModel.restEndDate)
        XCTAssertNil(viewModel.restStartDate)
    }

    /// Nothing to extend when not resting — guards against "+30s" resurrecting
    /// a countdown the user just skipped.
    func testExtendRestDoesNothingWhenNotResting() async {
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager()
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        viewModel.completeCurrentLiveSet()
        viewModel.skipRest()

        viewModel.extendRest(by: 30)

        XCTAssertNil(viewModel.restEndDate)
        XCTAssertNil(viewModel.restStartDate)
    }

    /// The exercise's plan-side context (notes / coach suggestion) has to reach
    /// the focus card, which reads it off the live session, not the plan.
    func testLiveSessionCarriesExerciseContextFromThePlan() async {
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(
                notes: "Elbows tucked",
                aiSuggestion: "Add 2.5kg from last week"
            ),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager()
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()

        let exercise = viewModel.activeLiveWorkout?.exercises.first
        XCTAssertEqual(exercise?.notes, "Elbows tucked")
        XCTAssertEqual(exercise?.aiSuggestion, "Add 2.5kg from last week")
    }

    /// The plan never populates `previousPerformanceSummary`, so the live
    /// session fills it from logged history after the workout starts.
    func testPreviousPerformanceIsBackfilledFromHistory() async {
        let library = LiveSessionExerciseLibraryService(lastSets: [
            ExerciseSet(id: "h1", setIndex: 1, weight: 57.5, weightUnit: .kg, reps: 8),
            ExerciseSet(id: "h2", setIndex: 2, weight: 57.5, weightUnit: .kg, reps: 8)
        ])
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: LiveSessionTrainingPlanService(),
            workoutService: LiveSessionWorkoutService(),
            liveActivityManager: LiveSessionActivityManager(),
            exerciseLibraryService: library
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()

        // The backfill is a detached task; give it a chance to land.
        for _ in 0..<50 where viewModel.activeLiveWorkout?.exercises.first?.previousPerformanceSummary == nil {
            await Task.yield()
        }

        XCTAssertEqual(
            viewModel.activeLiveWorkout?.exercises.first?.previousPerformanceSummary,
            "57.5 kg × 8 × 2"
        )
        XCTAssertTrue(
            library.excludedTodayFromLookup,
            "Today's own sets must be excluded, or the reference overwrites itself mid-workout"
        )
    }

    func testLiveActivityCompletionSyncsBeforeConfirmingSession() async {
        let trainingPlanService = LiveSessionTrainingPlanService()
        let workoutService = LiveSessionWorkoutService()
        let liveActivityManager = LiveSessionActivityManager()
        let viewModel = TodayWorkoutViewModel(
            trainingPlanService: trainingPlanService,
            workoutService: workoutService,
            liveActivityManager: liveActivityManager
        )

        await viewModel.refresh()
        viewModel.startPlanLiveWorkout()
        await Task.yield()
        liveActivityManager.externallyCompletedSetIds = ["plan-set-1"]
        viewModel.syncLiveActivityCompletions()
        await viewModel.confirmPlanLiveWorkout()

        XCTAssertEqual(trainingPlanService.completedPlanSetIds, ["plan-set-1"])
        XCTAssertEqual(viewModel.todayRecord?.exercises.first?.sets.count, 1)
    }
}

/// Supplies the PR baseline and unit preference the summary is built against.
private final class LiveSessionProfileService: ProfileServiceProtocol, @unchecked Sendable {
    private let prWeightKg: Double?

    init(prWeightKg: Double? = nil) {
        self.prWeightKg = prWeightKg
    }

    func fetchProfile() async throws -> UserProfile {
        UserProfile(
            id: "user-1",
            displayName: "Test",
            membershipLevel: .free,
            stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: 0, prCount: 0),
            preferences: .defaults(timezone: "UTC"),
            exercisePRs: prWeightKg.map {
                [ExercisePR(
                    normalizedName: "bench press",
                    displayName: "Bench Press",
                    maxWeight: $0,
                    weightUnit: .kg,
                    achievedAt: Date(timeIntervalSince1970: 0)
                )]
            } ?? []
        )
    }

    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences { .defaults() }
    func updateFitnessGoalSummary(_ summary: String) async throws -> String { summary }
    func fetchGoalSpec() async throws -> GoalSpec? { nil }
    func updateGoalSpec(_ spec: GoalSpec) async throws -> GoalSpec { spec }
}

/// Records whether the "last performed" lookup was date-bounded, which is what
/// keeps today's in-progress workout from becoming its own reference.
private final class LiveSessionExerciseLibraryService: ExerciseLibraryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let lastSets: [ExerciseSet]
    private var _excludedTodayFromLookup = false

    var excludedTodayFromLookup: Bool { lock.withLock { _excludedTodayFromLookup } }

    init(lastSets: [ExerciseSet]) {
        self.lastSets = lastSets
    }

    func fetchLibrary() async -> [ExerciseDefinition] { [] }
    func fetchRecentEntries(limit: Int) async -> [RecentExerciseEntry] { [] }
    func fetchRecommendations(todaysSelections: [ExerciseDefinition], limit: Int) async -> [ExerciseDefinition] { [] }
    func addCustomExercise(
        name: String,
        muscleGroup: MuscleGroup,
        loadType: ExerciseLoadType
    ) async throws -> ExerciseDefinition {
        fatalError("unused")
    }

    func fetchLastPerformedSets(exerciseId: String?, exerciseName: String) async -> [ExerciseSet]? {
        lastSets
    }

    func fetchLastPerformedSets(
        exerciseId: String?,
        exerciseName: String,
        before date: Date
    ) async -> [ExerciseSet]? {
        lock.withLock { _excludedTodayFromLookup = true }
        return lastSets
    }
}

private final class LiveSessionActivityManager: PlanLiveActivityManaging {
    private(set) var startedSessionIds: [String] = []
    private(set) var updatedSessionIds: [String] = []
    private(set) var didEndCount = 0
    var externallyCompletedSetIds: Set<String> = []

    func start(session: PlanLiveWorkoutSession) async {
        startedSessionIds.append(session.id)
    }

    func update(session: PlanLiveWorkoutSession) async {
        updatedSessionIds.append(session.id)
    }

    func end() async {
        didEndCount += 1
    }

    func consumeCompletedSetIds(sessionId: String) -> Set<String> {
        let ids = externallyCompletedSetIds
        externallyCompletedSetIds = []
        return ids
    }

    func completedSetIdUpdates(sessionId: String) -> AsyncStream<Set<String>> {
        AsyncStream { $0.finish() }
    }
}

// `@unchecked Sendable` + `NSLock`, matching `StubTokenProvider` in
// `SupabaseSDKTestSupport.swift`: the service protocols are `Sendable` (they are
// consumed concurrently via `async let`), so a recording double has to
// synchronize the state it records instead of storing a bare `var`.
private final class LiveSessionTrainingPlanService: TrainingPlanServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _completedPlanSetIds: [String] = []
    private let notes: String?
    private let aiSuggestion: String?

    init(notes: String? = nil, aiSuggestion: String? = nil) {
        self.notes = notes
        self.aiSuggestion = aiSuggestion
    }

    var completedPlanSetIds: [String] { lock.withLock { _completedPlanSetIds } }

    func fetchActiveWeeklyPlan() async throws -> TrainingPlan? { nil }

    func fetchTodayPlan() async throws -> TrainingPlanDay? {
        TrainingPlanDay(
            id: "plan-day-1",
            planDate: "2026-07-05",
            dayIndex: 1,
            title: "Push Strength",
            focus: "Chest",
            status: "planned",
            exercises: [
                TrainingPlanExercise(
                    id: "plan-exercise-1",
                    orderIndex: 0,
                    exerciseName: "Bench Press",
                    exerciseLoadType: .weighted,
                    progressionMode: "weight_first",
                    notes: notes,
                    previousPerformanceSummary: nil,
                    aiSuggestion: aiSuggestion,
                    sets: [
                        TrainingPlanSet(
                            id: "plan-set-1",
                            setIndex: 1,
                            targetWeight: 60,
                            targetWeightUnit: .kg,
                            targetReps: 8,
                            completedAt: nil,
                            linkedExerciseSetId: nil
                        ),
                        TrainingPlanSet(
                            id: "plan-set-2",
                            setIndex: 2,
                            targetWeight: 60,
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
        let setIndex = lock.withLock {
            _completedPlanSetIds.append(planSetId)
            return _completedPlanSetIds.count
        }
        return TrainingPlanSet(
            id: planSetId,
            setIndex: setIndex,
            targetWeight: actualWeight,
            targetWeightUnit: actualWeightUnit,
            targetReps: actualReps,
            completedAt: Date(),
            linkedExerciseSetId: "linked-\(planSetId)"
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
            setIndex: 3,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    func deletePlannedSet(planSetId: String) async throws {}

    func deletePlannedExercise(planExerciseId: String) async throws {}

    func addPlannedExercises(_ drafts: [PlanExerciseDraft]) async throws -> TrainingPlanDay {
        (try await fetchTodayPlan())!
    }

    func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay {
        (try await fetchTodayPlan())!
    }
}

private final class LiveSessionWorkoutService: WorkoutServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _persistedSetCount = 0

    private var persistedSetCount: Int {
        get { lock.withLock { _persistedSetCount } }
        set { lock.withLock { _persistedSetCount = newValue } }
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

    func addSet(sessionId: String, exerciseId: String, weight: Double?, weightUnit: WeightUnit, reps: Int) async throws -> ExerciseSet {
        ExerciseSet(id: UUID().uuidString, setIndex: 1, weight: weight, weightUnit: weightUnit, reps: reps)
    }

    func deleteSet(sessionId: String, exerciseId: String, setId: String) async throws {}
    func deleteExercise(sessionId: String, exerciseId: String) async throws {}
    func updateSetRPE(setId: String, rpe: Double?) async throws -> ExerciseSet {
        ExerciseSet(id: setId, setIndex: 1, weight: 60, weightUnit: .kg, reps: 8, rpe: rpe)
    }

    func activeDaysInMonth(year: Int, month: Int) async throws -> [Date] { [] }

    func sessionsForDay(_ date: Date) async throws -> [WorkoutSession] {
        [
            WorkoutSession(
                id: "session-1",
                userId: "user-1",
                date: date,
                durationMinutes: nil,
                label: "Push Strength",
                exercises: [
                    Exercise(
                        id: "exercise-1",
                        name: "Bench Press",
                        sets: (0..<persistedSetCount).map {
                            ExerciseSet(id: "set-\($0 + 1)", setIndex: $0 + 1, weight: 60, weightUnit: .kg, reps: 8)
                        }
                    )
                ],
                createdAt: date,
                updatedAt: date
            )
        ].filter { !$0.exercises.first!.sets.isEmpty }
    }

    func runningRecordsForDay(_ date: Date) async throws -> [RunningWorkoutRecord] { [] }

    func createStrengthSession(_ draft: StrengthSessionDraft) async throws -> WorkoutSession {
        persistedSetCount = draft.exercises.reduce(0) { $0 + $1.sets.count }
        return try await sessionsForDay(draft.workoutDate).first!
    }

    func createRunningRecord(
        workoutDate: Date,
        durationMinutes: Int,
        distanceKm: Double,
        source: RunningWorkoutSource
    ) async throws -> RunningWorkoutRecord {
        RunningWorkoutRecord(
            id: "run-1",
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
