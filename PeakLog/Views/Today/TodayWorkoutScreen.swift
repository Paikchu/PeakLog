import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TodayWorkoutScreen: View {
    // Owned by ContentView so the dock can surface the start-training action.
    @ObservedObject var viewModel: TodayWorkoutViewModel
    @EnvironmentObject private var syncController: CloudSyncController
    @State private var isPresentingAddPlanExercise = false
    @State private var isPresentingFinishDialog = false
    @State private var isPresentingCancelDialog = false
    @State private var replanToast: ReplanToast?
    // 专注模式滚动编排：scrolledExerciseId 追踪屏幕中心的卡片，displayedExerciseId 决定哪张卡展开。
    @State private var scrolledExerciseId: String?
    @State private var displayedExerciseId: String?
    @State private var focusSettleTask: Task<Void, Never>?
    @State private var flowAdvanceTask: Task<Void, Never>?
    @State private var isReorderingPlan = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFocusMode: Bool {
        viewModel.isTrainingFocusActive && viewModel.activeLiveWorkout != nil
    }

    private var summaryState: TodaySummarySection.State {
        TodaySummarySection.State(
            plan: viewModel.todayPlan,
            todayRecord: viewModel.todayRecord,
            runningRecords: viewModel.runningRecords
        )
    }

    private var planState: TodayPlanExercisesSection.State? {
        guard let plan = viewModel.todayPlan else { return nil }
        return TodayPlanExercisesSection.State(
            plan: plan,
            focusSession: viewModel.activeLiveWorkout,
            isFocusMode: isFocusMode,
            displayedExerciseId: displayedExerciseId,
            reduceMotion: reduceMotion,
            sessionCompletedSetIds: viewModel.activeLiveWorkout?.completedSetIds ?? []
        )
    }

    private var recordsState: TodayRecordsSection.State {
        TodayRecordsSection.State(
            hasPlan: viewModel.todayPlan != nil,
            record: viewModel.todayRecord,
            runningRecords: viewModel.runningRecords
        )
    }

    private var flowAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.82)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if viewModel.isLoading {
                    ProgressView().padding(.top, 40)
                } else {
                    if !isFocusMode {
                        if let session = viewModel.activeLiveWorkout {
                            TodayActiveSessionBanner(
                                session: session,
                                locale: locale,
                                flowAnimation: flowAnimation,
                                onResume: viewModel.resumeTrainingFocus
                            )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        TodaySummarySection(state: summaryState, locale: locale)
                            .transition(.opacity)
                        if showReplanMenu {
                            replanMenu
                                .transition(.opacity)
                        }
                    }
                    if let planState {
                        TodayPlanExercisesSection(
                            state: planState,
                            isReordering: $isReorderingPlan,
                            flowAnimation: flowAnimation,
                            onSetScrolled: { id in
                                scrolledExerciseId = id
                                displayedExerciseId = id
                            },
                            onUpdateSet: { setId, weight, unit, reps in
                                Task {
                                    await viewModel.updatePlannedSet(
                                        planSetId: setId,
                                        targetWeight: weight,
                                        targetWeightUnit: unit,
                                        targetReps: reps
                                    )
                                }
                            },
                            onCompleteSet: { setId, rpe in
                                Task { await viewModel.completePlannedSet(planSetId: setId, rpe: rpe) }
                            },
                            onAddSet: { exerciseId in
                                Task { await viewModel.addPlannedSet(planExerciseId: exerciseId) }
                            },
                            onDeleteLastSet: { exerciseId in
                                Task { await viewModel.deleteLastPlannedSet(planExerciseId: exerciseId) }
                            },
                            onToggleLiveSet: viewModel.toggleLiveSet,
                            onSkipCurrentLiveExercise: {
                                withAnimation(flowAnimation) {
                                    viewModel.skipCurrentLiveExercise()
                                }
                            },
                            onReorderExercises: { orderedIds in
                                Task { await viewModel.reorderTodayPlanExercises(orderedExerciseIds: orderedIds) }
                            },
                            onDeleteExercise: { exerciseId in
                                Task { await viewModel.deletePlanExercise(planExerciseId: exerciseId) }
                            }
                        )
                    }
                    if !isFocusMode {
                        TodayInlineAddRow(onAddPlanExercise: { isPresentingAddPlanExercise = true })
                            .transition(.opacity)
                    }
                    if !isFocusMode {
                        TodayRecordsSection(
                            state: recordsState,
                            record: Binding(
                                get: { viewModel.todayRecord ?? recordsState.record },
                                set: { viewModel.todayRecord = $0 }
                            ),
                            onSetChanged: { exerciseId, updatedSet in
                                Task { await viewModel.updateLoggedSet(exerciseId: exerciseId, updatedSet: updatedSet) }
                            },
                            onAddSet: { exerciseId in
                                Task { await viewModel.addLoggedSet(exerciseId: exerciseId) }
                            },
                            onDeleteLastSet: { exerciseId in
                                Task { await viewModel.deleteLastLoggedSet(exerciseId: exerciseId) }
                            },
                            onDeleteExercise: { exerciseId in
                                Task { await viewModel.deleteLoggedExercise(exerciseId: exerciseId) }
                            }
                        )
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // 专注模式底部留白加大，让最后一个动作也能滚到屏幕中间。
            .padding(.bottom, isFocusMode ? 320 : 104)
        }
        .scrollPosition(id: $scrolledExerciseId, anchor: .center)
        .scrollDisabled(isReorderingPlan)
        .dismissKeyboardOnTap()
        .background(Color.appBackground.ignoresSafeArea())
        .dismissKeyboardOnTap()
        .overlay(alignment: .bottom) {
            if let toast = replanToast {
                replanToastView(toast)
                    .padding(.bottom, isFocusMode ? 340 : 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(flowAnimation, value: replanToast)
        .safeAreaInset(edge: .top) {
            if isFocusMode, let session = viewModel.activeLiveWorkout {
                TodayFocusHeader(
                    session: session,
                    locale: locale,
                    flowAnimation: flowAnimation,
                    onMinimize: viewModel.minimizeTrainingFocus,
                    onFinish: {
                        if session.isComplete {
                            Task { await viewModel.confirmPlanLiveWorkout() }
                        } else {
                            isPresentingFinishDialog = true
                        }
                    },
                    onCancel: {
                        isPresentingCancelDialog = true
                    }
                )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(flowAnimation, value: isFocusMode)
        .task { await viewModel.onAppear() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            viewModel.syncLiveActivityCompletions()
        }
        .onChange(of: isFocusMode) { _, isActive in
#if canImport(UIKit)
            // 训练中保持屏幕常亮。
            UIApplication.shared.isIdleTimerDisabled = isActive
#endif
            if isActive {
                // 训练进行中不支持调整顺序，进入专注模式时强制退出重排。
                isReorderingPlan = false
                let currentId = viewModel.activeLiveWorkout?.currentExercise?.id
                displayedExerciseId = currentId
                // 等布局切换过渡启动后，再把当前动作流动到屏幕中间。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(flowAnimation) {
                        scrolledExerciseId = currentId
                    }
                }
            } else {
                focusSettleTask?.cancel()
                flowAdvanceTask?.cancel()
                displayedExerciseId = nil
                scrolledExerciseId = nil
            }
        }
        .onChange(of: viewModel.activeLiveWorkout?.currentExercise?.id) { _, newId in
            guard isFocusMode, let newId, newId != displayedExerciseId else { return }
            // 动作完成后停留一拍展示完成态，再流转到下一个动作。
            flowAdvanceTask?.cancel()
            flowAdvanceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(flowAnimation) {
                    displayedExerciseId = newId
                    scrolledExerciseId = newId
                }
            }
        }
        .onChange(of: scrolledExerciseId) { _, newId in
            guard isFocusMode, let newId else { return }
            // 滑动停稳（250ms 防抖）即展开并锁定该动作。
            focusSettleTask?.cancel()
            focusSettleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(flowAnimation) {
                    displayedExerciseId = newId
                }
                if newId != viewModel.activeLiveWorkout?.currentExercise?.id {
                    viewModel.focusLiveExercise(id: newId)
#if canImport(UIKit)
                    UISelectionFeedbackGenerator().selectionChanged()
#endif
                }
            }
        }
        .onDisappear {
#if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
#endif
        }
        .sheet(isPresented: $isPresentingAddPlanExercise) {
            AddPlanExerciseSheet { drafts in
                await viewModel.addPlanExercises(drafts)
            }
        }
        .confirmationDialog(
            "training_session.finish_incomplete.title",
            isPresented: $isPresentingFinishDialog,
            titleVisibility: .visible
        ) {
            Button("training_session.finish") {
                Task { await viewModel.confirmPlanLiveWorkout() }
            }
        } message: {
            Text(LocalizedPlanText.formatted(
                "training_session.finish_incomplete.message",
                locale: locale,
                Int64(remainingSetsCount)
            ))
        }
        .confirmationDialog(
            "training_session.cancel_confirm.title",
            isPresented: $isPresentingCancelDialog,
            titleVisibility: .visible
        ) {
            Button("training_session.cancel", role: .destructive) {
                withAnimation(flowAnimation) {
                    viewModel.cancelPlanLiveWorkout()
                }
            }
        } message: {
            Text("training_session.cancel_confirm.message")
        }
        .alert("common.error_title", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var remainingSetsCount: Int {
        guard let session = viewModel.activeLiveWorkout else { return 0 }
        return session.totalSetsCount - session.completedSetsCount
    }

}

// MARK: - One-tap mid-week replan (Phase 3)

struct ReplanToast: Equatable {
    let message: String
    let isError: Bool
}

private extension TodayWorkoutScreen {
    /// Shown under the summary when: there is a training day today with actual
    /// exercises, we're not mid-focus-session, and a cloud session exists to
    /// carry the request. A rest day or a brand-new local-only user sees nothing.
    var showReplanMenu: Bool {
        guard syncController.isReplanAvailable, !isFocusMode else { return false }
        guard let plan = viewModel.todayPlan else { return false }
        return !plan.exercises.isEmpty
    }

    var replanMenu: some View {
        Menu {
            ForEach(ReplanSignal.allCases, id: \.self) { signal in
                Button {
                    Task { await handleReplan(signal) }
                } label: {
                    Label(signal.menuTitle, systemImage: signal.menuIcon)
                }
                .disabled(signal.requiresUntrainedToday && viewModel.todayHasCompletedSets)
            }
        } label: {
            HStack(spacing: 6) {
                if syncController.isRequestingReplan {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "slider.horizontal.3")
                }
                Text(String(localized: "today.replan.menu", defaultValue: "调整今天"))
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            )
        }
        .disabled(syncController.isRequestingReplan)
    }

    func replanToastView(_ toast: ReplanToast) -> some View {
        Text(toast.message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(toast.isError ? Color.red.opacity(0.92) : Color.black.opacity(0.82))
            )
            .padding(.horizontal, 24)
            .shadow(radius: 8, y: 2)
    }

    func handleReplan(_ signal: ReplanSignal) async {
        // Record the user's signal locally first — it must reach the learning
        // loop even if the server call fails (Phase 3 plan §4.1).
        await viewModel.recordDaySignal(signal)

        let outcome = await syncController.requestReplan(signal: signal)
        switch outcome {
        case .replanned:
            await viewModel.refresh()
            showToast(String(localized: "today.replan.done", defaultValue: "已为你调整今天的计划"), isError: false)
        case .noChange:
            showToast(String(localized: "today.replan.no_change", defaultValue: "今天暂时无需调整"), isError: false)
        case .failed, .none:
            // The plan is intentionally left untouched on failure — say so plainly.
            showToast(String(localized: "today.replan.failed", defaultValue: "暂时无法调整，计划保持不变"), isError: true)
        }
    }

    func showToast(_ message: String, isError: Bool) {
        replanToast = ReplanToast(message: message, isError: isError)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if replanToast?.message == message { replanToast = nil }
        }
    }
}

private struct TodayFocusHeader: View {
    let session: PlanLiveWorkoutSession
    let locale: Locale
    let flowAnimation: Animation?
    let onMinimize: () -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(flowAnimation, onMinimize)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 32, height: 32)
                        .glassChip(cornerRadius: AppRadius.full)
                }
                .accessibilityLabel(Text("training_session.minimize"))
                .accessibilityIdentifier("training_focus.minimize")

                Text(TodayPlanHeader.resolve(
                    planTitle: session.title,
                    focus: session.focus,
                    fallbackTitle: String(localized: "today.header.default_title")
                ).title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(session.completedSetsCount)/\(session.totalSetsCount)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
                    .contentTransition(.numericText())
                    .animation(flowAnimation, value: session.completedSetsCount)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .glassChip(cornerRadius: AppRadius.full)

                Menu {
                    Button(action: onFinish) {
                        Label(String(localized: "training_session.finish"), systemImage: "checkmark.circle")
                    }

                    Button(role: .destructive, action: onCancel) {
                        Label(String(localized: "training_session.cancel"), systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 32, height: 32)
                        .glassChip(cornerRadius: AppRadius.full)
                }
                .accessibilityIdentifier("training_focus.menu")
            }

            PlanProgressBar(progress: session.progress)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }
}

private struct TodayActiveSessionBanner: View {
    let session: PlanLiveWorkoutSession
    let locale: Locale
    let flowAnimation: Animation?
    let onResume: () -> Void

    var body: some View {
        Button {
            withAnimation(flowAnimation, onResume)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("training_session.in_progress")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text(LocalizedPlanText.setsCompleted(
                        completed: session.completedSetsCount,
                        total: session.totalSetsCount,
                        locale: locale
                    ))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textSecondary)
                }

                Spacer()

                Text("training_session.resume")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassActionBackground(cornerRadius: AppRadius.full, tint: Color.accentPrimary.opacity(0.45))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassPanel(cornerRadius: AppRadius.xl)
        .accessibilityIdentifier("training_focus.resumeBanner")
    }
}

private struct TodaySummarySection: View {
    struct State {
        let plan: TrainingPlanDay?
        let todayRecord: WorkoutRecord?
        let runningRecords: [RunningWorkoutRecord]

        var totalDuration: Int {
            runningRecords.reduce(0) { $0 + $1.durationMinutes }
        }

        var totalDistance: Double {
            runningRecords.reduce(0) { $0 + $1.distanceKm }
        }
    }

    let state: State
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = state.plan {
                planSummary(plan)
            } else if state.todayRecord != nil {
                freeRecordSummary
            } else if !state.runningRecords.isEmpty {
                runningOnlySummary
            } else {
                emptySummary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planSummary(_ plan: TrainingPlanDay) -> some View {
        let header = TodayPlanHeader.resolve(
            planTitle: plan.title,
            focus: plan.focus,
            fallbackTitle: String(localized: "today.header.default_title")
        )
        let isPlanComplete = plan.totalSetsCount > 0 && plan.completedSetsCount >= plan.totalSetsCount

        return VStack(alignment: .leading, spacing: 10) {
            RootPageHeader(eyebrow: TodayHeaderDateText.eyebrow(locale: locale), title: header.title, subtitle: header.subtitle) {
                if isPlanComplete { completedChip } else { Color.clear }
            }
            if plan.totalSetsCount > 0 {
                HStack(spacing: 10) {
                    PlanProgressBar(
                        progress: Double(plan.completedSetsCount) / Double(plan.totalSetsCount),
                        isComplete: isPlanComplete
                    )
                    Text(LocalizedPlanText.formatted(
                        "today.header.sets_progress",
                        locale: locale,
                        Int64(plan.completedSetsCount),
                        Int64(plan.totalSetsCount)
                    ))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.textSecondary)
                    .contentTransition(.numericText())
                }
                .padding(.horizontal, RootPageHeaderMetrics.horizontalPadding)
                .padding(.top, 2)
            }

            runningPlanSummary
        }
    }

    @ViewBuilder
    private var runningPlanSummary: some View {
        if !state.runningRecords.isEmpty {
            Text(LocalizedPlanText.todayRunningSummary(
                distance: state.totalDistance.cleanDistance,
                durationMinutes: state.totalDuration,
                count: state.runningRecords.count,
                locale: locale
            ))
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.textSecondary)
            .padding(.horizontal, RootPageHeaderMetrics.horizontalPadding)
            .padding(.top, 2)
        }
    }

    private var freeRecordSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            RootPageHeader(
                eyebrow: TodayHeaderDateText.eyebrow(locale: locale),
                title: String(localized: "today.summary.free_record_day.title"),
                subtitle: String(localized: "today.summary.free_record_day.subtitle")
            )
            runningPlanSummary
        }
    }

    private var runningOnlySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            RootPageHeader(
                eyebrow: TodayHeaderDateText.eyebrow(locale: locale),
                title: String(localized: "today.summary.running_only.title"),
                subtitle: LocalizedPlanText.todayRunningRecordsSummary(
                    distance: state.totalDistance.cleanDistance,
                    durationMinutes: state.totalDuration,
                    count: state.runningRecords.count,
                    locale: locale
                )
            )
        }
    }

    private var emptySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            RootPageHeader(
                eyebrow: TodayHeaderDateText.eyebrow(locale: locale),
                title: String(localized: "today.summary.empty.title"),
                subtitle: String(localized: "today.summary.empty.subtitle")
            )
        }
    }

    private var completedChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text("today.header.completed")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.green.opacity(0.14)))
        .transition(.scale.combined(with: .opacity))
    }
}

private struct TodayPlanExercisesSection: View {
    struct State {
        let plan: TrainingPlanDay
        let focusSession: PlanLiveWorkoutSession?
        let isFocusMode: Bool
        let displayedExerciseId: String?
        let reduceMotion: Bool
        let sessionCompletedSetIds: Set<String>
    }

    let state: State
    @Binding var isReordering: Bool
    let flowAnimation: Animation?
    let onSetScrolled: (String) -> Void
    let onUpdateSet: (String, Double?, WeightUnit, Int) -> Void
    let onCompleteSet: (String, Double?) -> Void
    let onAddSet: (String) -> Void
    let onDeleteLastSet: (String) -> Void
    let onToggleLiveSet: (String) -> Void
    let onSkipCurrentLiveExercise: () -> Void
    let onReorderExercises: ([String]) -> Void
    let onDeleteExercise: (String) -> Void

    @SwiftUI.State private var draftOrder: [TrainingPlanExercise] = []

    var body: some View {
        Group {
            if isReordering {
                ReorderableExerciseList(
                    items: $draftOrder,
                    sessionCompletedSetIds: state.sessionCompletedSetIds,
                    onCommit: onReorderExercises,
                    onDone: {
                        withAnimation(flowAnimation) { isReordering = false }
                    }
                )
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: state.isFocusMode ? 10 : 16) {
                    ForEach(state.plan.exercises) { exercise in
                        exerciseCard(for: exercise)
                            .id(exercise.id)
                            .visualEffect { content, proxy in
                                let containerHeight = proxy.bounds(of: .scrollView(axis: .vertical))?.height ?? 800
                                let midY = proxy.frame(in: .scrollView(axis: .vertical)).midY
                                let distance = min(abs(midY - containerHeight / 2) / max(containerHeight / 2, 1), 1)
                                let scale = state.isFocusMode && !state.reduceMotion ? 1 - 0.04 * distance : 1
                                let opacity = state.isFocusMode ? 1 - 0.35 * distance : 1
                                return content
                                    .scaleEffect(scale)
                                    .opacity(opacity)
                            }
                    }
                }
                .scrollTargetLayout()
                // 滑动删除动作后列表平滑收拢。
                .animation(flowAnimation, value: state.plan.exercises.map(\.id))
            }
        }
    }

    @ViewBuilder
    private func exerciseCard(for exercise: TrainingPlanExercise) -> some View {
        if state.isFocusMode, let session = state.focusSession {
            let liveModel = session.exercise(withId: exercise.id) ?? liveExercise(from: exercise)
            if state.displayedExerciseId == exercise.id {
                FocusExerciseCard(
                    exercise: liveModel,
                    session: session,
                    isCurrent: session.currentExercise?.id == exercise.id,
                    onToggleSet: onToggleLiveSet,
                    onSkip: onSkipCurrentLiveExercise
                )
                .transition(.opacity)
            } else {
                FocusCollapsedExerciseRow(
                    exercise: liveModel,
                    session: session,
                    onTap: {
                        withAnimation(flowAnimation) {
                            onSetScrolled(exercise.id)
                        }
                    }
                )
                .transition(.opacity)
            }
        } else {
            // 由右向左滑动删除该计划动作（已完成的动作同样支持）。
            SwipeToDeleteRow(onDelete: { onDeleteExercise(exercise.id) }) {
                TodayPlannedExerciseCard(
                    exercise: exercise,
                    sessionCompletedSetIds: state.sessionCompletedSetIds,
                    onUpdateSet: onUpdateSet,
                    onCompleteSet: onCompleteSet,
                    onAddSet: { onAddSet(exercise.id) },
                    onDeleteLastSet: { onDeleteLastSet(exercise.id) },
                    onLongPressHeader: {
                        draftOrder = state.plan.exercises
#if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
                        withAnimation(flowAnimation) { isReordering = true }
                    }
                )
            }
        }
    }

    private func liveExercise(from exercise: TrainingPlanExercise) -> PlanLiveWorkoutExercise {
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
}

private struct ReorderableExerciseList: View {
    @Binding var items: [TrainingPlanExercise]
    let sessionCompletedSetIds: Set<String>
    let onCommit: ([String]) -> Void
    let onDone: () -> Void

    @State private var draggingId: String?
    @State private var dragOffset: CGFloat = 0

    private let rowHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("today.plan.reorder.title")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textSecondary)
                Spacer()
                Button(action: onDone) {
                    Text("common.done")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.accentPrimary)
                }
                .accessibilityIdentifier("today.plan.reorderDone")
            }
            .padding(.horizontal, 4)

            VStack(spacing: rowSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, exercise in
                    row(for: exercise, index: index)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for exercise: TrainingPlanExercise, index: Int) -> some View {
        let isDragging = draggingId == exercise.id
        let completedSets = exercise.sets.count { $0.isCompleted || sessionCompletedSetIds.contains($0.id) }

        ReorderableExerciseRow(
            name: exercise.exerciseName,
            completedSets: completedSets,
            totalSets: exercise.sets.count,
            isDragging: isDragging
        )
        .frame(height: rowHeight)
        .zIndex(isDragging ? 1 : 0)
        .offset(y: isDragging ? dragOffset : 0)
        .accessibilityAction(named: Text("today.plan.reorder.move_up")) {
            guard index > 0 else { return }
            move(from: index, to: index - 1)
        }
        .accessibilityAction(named: Text("today.plan.reorder.move_down")) {
            guard index < items.count - 1 else { return }
            move(from: index, to: index + 1)
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if draggingId == nil {
                        draggingId = exercise.id
#if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
                    }
                    guard draggingId == exercise.id else { return }
                    dragOffset = value.translation.height

                    let step = rowHeight + rowSpacing
                    let shift = Int((dragOffset / step).rounded())
                    guard shift != 0,
                          let currentIndex = items.firstIndex(where: { $0.id == exercise.id }) else { return }
                    let targetIndex = max(0, min(items.count - 1, currentIndex + shift))
                    guard targetIndex != currentIndex else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        items.move(
                            fromOffsets: IndexSet(integer: currentIndex),
                            toOffset: targetIndex > currentIndex ? targetIndex + 1 : targetIndex
                        )
                    }
                    dragOffset -= CGFloat(targetIndex - currentIndex) * step
#if canImport(UIKit)
                    UISelectionFeedbackGenerator().selectionChanged()
#endif
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                    draggingId = nil
                    onCommit(items.map(\.id))
                }
        )
    }

    private func move(from source: Int, to destination: Int) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            items.move(
                fromOffsets: IndexSet(integer: source),
                toOffset: destination > source ? destination + 1 : destination
            )
        }
        onCommit(items.map(\.id))
    }
}

private struct ReorderableExerciseRow: View {
    let name: String
    let completedSets: Int
    let totalSets: Int
    let isDragging: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: AppRadius.full)
                .fill(Color.accentPrimary)
                .frame(width: 5, height: 22)

            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.textPrimary)
                .lineLimit(1)

            Spacer()

            Text(LocalizedPlanText.formatted(
                "today.plan.reorder.sets_badge",
                locale: locale,
                Int64(completedSets),
                Int64(totalSets)
            ))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.textSecondary)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.textMuted)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Color.workoutPanel)
        )
        .scaleEffect(isDragging ? 1.03 : 1)
        .shadow(color: Color.black.opacity(isDragging ? 0.18 : 0), radius: isDragging ? 10 : 0, y: isDragging ? 4 : 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct TodayInlineAddRow: View {
    let onAddPlanExercise: () -> Void

    var body: some View {
        Button(action: onAddPlanExercise) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                Text("today.add_menu.plan_exercise")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.accentPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .strokeBorder(
                        Color.accentPrimary.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("today.addPlanExercise")
    }
}

private struct TodayRecordsSection: View {
    struct State {
        let hasPlan: Bool
        let record: WorkoutRecord?
        let runningRecords: [RunningWorkoutRecord]
    }

    let state: State
    let record: Binding<WorkoutRecord?>
    let onSetChanged: (String, ExerciseSet) -> Void
    let onAddSet: (String) -> Void
    let onDeleteLastSet: (String) -> Void
    let onDeleteExercise: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.hasPlan, let recordValue = state.record {
                sectionHeader(
                    title: String(localized: "today.section.strength_record.title"),
                    subtitle: String(localized: "today.section.strength_record.subtitle")
                )

                WorkoutRecordCard(
                    record: Binding(
                        get: { record.wrappedValue ?? recordValue },
                        set: { record.wrappedValue = $0 }
                    ),
                    isEditable: true,
                    onSetChanged: onSetChanged,
                    onAddSet: onAddSet,
                    onDeleteLastSet: onDeleteLastSet,
                    onDeleteExercise: onDeleteExercise
                )
            }

            if !state.runningRecords.isEmpty {
                sectionHeader(
                    title: String(localized: "today.section.cardio_record.title"),
                    subtitle: String(localized: "today.section.cardio_record.subtitle")
                )

                ForEach(state.runningRecords) { record in
                    RunningRecordCard(record: record)
                }
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.textPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Double {
    var cleanDistance: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }
}

private struct TodayPlannedExerciseCard: View {
    let exercise: TrainingPlanExercise
    /// 活跃 session 中已完成但尚未落库的组，用于浏览模式下同步显示勾选状态。
    let sessionCompletedSetIds: Set<String>
    let onUpdateSet: (String, Double?, WeightUnit, Int) -> Void
    let onCompleteSet: (String, Double?) -> Void
    let onAddSet: () -> Void
    let onDeleteLastSet: () -> Void
    let onLongPressHeader: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: AppRadius.full)
                        .fill(Color.accentPrimary)
                        .frame(width: 5, height: 22)

                    Text(exercise.exerciseName)
                        .font(.exerciseName)
                        .foregroundColor(.textPrimary)

                    if let previous = exercise.previousPerformanceSummary, !previous.isEmpty {
                        Text(previous)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.textMuted)
                    }
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.4, perform: onLongPressHeader)

                Spacer()

                if exercise.sets.count > 1 {
                    Button(action: onDeleteLastSet) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.textMuted)
                    }
                }

                Button(action: onAddSet) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.accentPrimary)
                }
            }
            if let suggestion = exercise.aiSuggestion, !suggestion.isEmpty {
                Text(suggestion)
                    .font(.system(size: 12))
                    .foregroundColor(.accentPrimary.opacity(0.92))
            }

            VStack(spacing: 0) {
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                    TodayPlannedSetRow(
                        set: set,
                        exerciseId: exercise.exerciseId,
                        exerciseName: exercise.exerciseName,
                        exerciseLoadType: exercise.exerciseLoadType,
                        precedingSet: index > 0 ? exercise.sets[index - 1] : nil,
                        isCompletedInSession: sessionCompletedSetIds.contains(set.id),
                        onCommit: { weight, unit, reps in
                            onUpdateSet(set.id, weight, unit, reps)
                        },
                        onToggleComplete: { rpe in
                            onCompleteSet(set.id, rpe)
                        }
                    )

                    if set.id != exercise.sets.last?.id {
                        Rectangle()
                            .fill(Color.appSeparator)
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct TodayPlannedSetRow: View {
    let set: TrainingPlanSet
    let exerciseId: String?
    let exerciseName: String
    let exerciseLoadType: ExerciseLoadType
    let precedingSet: TrainingPlanSet?
    let isCompletedInSession: Bool
    let onCommit: (Double?, WeightUnit, Int) -> Void
    let onToggleComplete: (Double?) -> Void
    @Environment(\.locale) private var locale

    @State private var editingWeight = false
    @State private var editingReps = false
    @State private var weightSuggestion: SetDefaultsSuggestion?
    @State private var repsSuggestion: SetDefaultsSuggestion?

    private var showsCompleted: Bool {
        self.set.isCompleted || isCompletedInSession
    }

    private var allowsBodyweightToggle: Bool {
        exerciseLoadType == .bodyweight
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(set.setIndex)")
                .font(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            Button {
                presentWeightEditor()
            } label: {
                LoadValueLabel(
                    weight: set.targetWeight,
                    weightUnit: set.targetWeightUnit,
                    isBodyweight: allowsBodyweightToggle && set.targetWeight == nil,
                    unsetPlaceholder: allowsBodyweightToggle ? nil : exerciseLoadType.displayLabel
                )
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel)
                )
            }

            Text("×")
                .font(.setIndex)
                .foregroundColor(Color.accentBorder.opacity(0.55))

            Button {
                presentRepsEditor()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(set.targetReps)")
                        .font(.exerciseValue)
                        .foregroundColor(.accentValue)
                    Text("chat.exercise.reps")
                        .font(.exerciseUnit)
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel)
                )
            }

            Button(action: {
                onToggleComplete(nil)
#if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
            }) {
                Image(systemName: showsCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(showsCompleted ? .green : .textMuted)
            }
            .disabled(showsCompleted)
            .contextMenu {
                ForEach([6, 7, 8, 9, 10], id: \.self) { value in
                    Button(LocalizedPlanText.formatted("today.plan.complete_with_rpe", locale: locale, Int64(value))) {
                        onToggleComplete(Double(value))
#if canImport(UIKit)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $editingWeight) {
            WeightWheelEditSheet(
                allowsBodyweightToggle: allowsBodyweightToggle,
                weightUnit: set.targetWeightUnit,
                initialWeight: set.targetWeight,
                lastTime: weightSuggestion
            ) { weight in
                onCommit(weight, set.targetWeightUnit, set.targetReps)
                editingWeight = false
            } onCancel: {
                editingWeight = false
            }
            .presentationDetents([.height(allowsBodyweightToggle ? 420 : 380)])
        }
        .sheet(isPresented: $editingReps) {
            RepsWheelEditSheet(initialReps: set.targetReps, lastTime: repsSuggestion) { reps in
                onCommit(set.targetWeight, set.targetWeightUnit, reps)
                editingReps = false
            } onCancel: {
                editingReps = false
            }
            .presentationDetents([.height(360)])
        }
    }

    private func precedingSuggestion() -> SetDefaultsSuggestion? {
        precedingSet.map {
            SetDefaultsSuggestion(weight: $0.targetWeight, weightUnit: $0.targetWeightUnit, reps: $0.targetReps)
        }
    }

    private func presentWeightEditor() {
        Task {
            weightSuggestion = await AppServices.setDefaultsProvider.suggestDefaults(for: SetDefaultsContext(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                setIndex: set.setIndex,
                precedingSetInSameExercise: precedingSuggestion()
            ))
            editingWeight = true
        }
    }

    private func presentRepsEditor() {
        Task {
            repsSuggestion = await AppServices.setDefaultsProvider.suggestDefaults(for: SetDefaultsContext(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                setIndex: set.setIndex,
                precedingSetInSameExercise: precedingSuggestion()
            ))
            editingReps = true
        }
    }
}

struct PlanProgressBar: View {
    let progress: Double
    var isComplete = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.appSeparator)
                Capsule()
                    .fill(fillStyle)
                    .frame(width: max(proxy.size.width * progress, progress > 0 ? 18 : 0))
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: progress)
            }
        }
        .frame(height: 8)
    }

    private var fillStyle: LinearGradient {
        if isComplete {
            return LinearGradient(
                colors: [Color.green.opacity(0.75), Color.green],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient.accentGradient
    }
}

extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26, *) {
            self
                .background(Color.appSurface.opacity(0.18))
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassChip(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26, *) {
            self
                .background(Color.workoutPanel.opacity(0.18))
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(Color.workoutPanel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassActionBackground(cornerRadius: CGFloat, tint: Color) -> some View {
        if #available(iOS 26, *) {
            self
                .background(tint)
                .glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint)
                )
        }
    }
}

private struct TodayWorkoutScreenPreview: View {
    // `#Preview` 闭包在本项目（Swift 5 语言模式）下并非 Main Actor 隔离，
    // 而 `TodayWorkoutViewModel` 的 init 是 @MainActor 的。把预览内容放到
    // `@MainActor` 的 `body` 里构造，即可在正确的执行上下文创建 ViewModel，
    // 消除 “在同步非隔离上下文中调用 Main Actor 隔离的 init()” 的告警。
    @MainActor
    var body: some View {
        TodayWorkoutScreen(viewModel: TodayWorkoutViewModel())
            .environmentObject(CloudSyncController())
    }
}

#Preview {
    TodayWorkoutScreenPreview()
}
