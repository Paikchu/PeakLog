import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TodayWorkoutScreen: View {
    // Owned by ContentView so the dock can surface the start-training action.
    @ObservedObject var viewModel: TodayWorkoutViewModel
    @State private var isPresentingDailyRecord = false
    @State private var isPresentingAddPlanExercise = false
    @State private var isPresentingFinishDialog = false
    @State private var isPresentingCancelDialog = false
    // 专注模式滚动编排：scrolledExerciseId 追踪屏幕中心的卡片，displayedExerciseId 决定哪张卡展开。
    @State private var scrolledExerciseId: String?
    @State private var displayedExerciseId: String?
    @State private var focusSettleTask: Task<Void, Never>?
    @State private var flowAdvanceTask: Task<Void, Never>?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFocusMode: Bool {
        viewModel.isTrainingFocusActive && viewModel.activeLiveWorkout != nil
    }

    private var flowAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.82)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 18) {
                    if viewModel.isLoading {
                        ProgressView().padding(.top, 40)
                    } else {
                        if !isFocusMode {
                            if viewModel.activeLiveWorkout != nil {
                                activeSessionBanner
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            summaryCard
                                .transition(.opacity)
                        }
                        plannedSection
                        if !isFocusMode {
                            recordedSection
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
            .dismissKeyboardOnTap()

            if !isFocusMode {
                addRecordButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 22)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .dismissKeyboardOnTap()
        .safeAreaInset(edge: .top) {
            if isFocusMode, let session = viewModel.activeLiveWorkout {
                focusHeader(session)
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
        .sheet(isPresented: $isPresentingDailyRecord) {
            DailyRecordSheet { draft in
                await viewModel.addDailyRecord(draft)
            }
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

    // MARK: - 专注模式顶部紧凑头

    private func focusHeader(_ session: PlanLiveWorkoutSession) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(flowAnimation) {
                        viewModel.minimizeTrainingFocus()
                    }
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
                    Button {
                        if session.isComplete {
                            Task { await viewModel.confirmPlanLiveWorkout() }
                        } else {
                            isPresentingFinishDialog = true
                        }
                    } label: {
                        Label(String(localized: "training_session.finish"), systemImage: "checkmark.circle")
                    }

                    Button(role: .destructive) {
                        isPresentingCancelDialog = true
                    } label: {
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

    // MARK: - 最小化训练横幅（浏览模式 + session 活跃）

    private var activeSessionBanner: some View {
        Button {
            withAnimation(flowAnimation) {
                viewModel.resumeTrainingFocus()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("training_session.in_progress")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.textPrimary)
                    if let session = viewModel.activeLiveWorkout {
                        Text(LocalizedPlanText.setsCompleted(
                            completed: session.completedSetsCount,
                            total: session.totalSetsCount,
                            locale: locale
                        ))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)
                    }
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

    private var addRecordButton: some View {
        Menu {
            Button {
                isPresentingAddPlanExercise = true
            } label: {
                Label(String(localized: "today.add_menu.plan_exercise"), systemImage: "calendar.badge.plus")
            }
            .accessibilityIdentifier("today.addPlanExercise")

            Button {
                isPresentingDailyRecord = true
            } label: {
                Label(String(localized: "today.add_menu.daily_record"), systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("today.addDailyRecord")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
                .background(addRecordButtonBackground)
        }
        .accessibilityLabel("Add daily record")
        .accessibilityIdentifier("today.addRecordMenu")
    }

    @ViewBuilder
    private var addRecordButtonBackground: some View {
        if #available(iOS 26, *) {
            Circle()
                .fill(Color.accentPrimary.opacity(0.32))
                .glassEffect(.regular.tint(Color.accentPrimary.opacity(0.25)).interactive(), in: .rect(cornerRadius: 29))
                .shadow(color: Color.accentPrimary.opacity(0.24), radius: 18, x: 0, y: 10)
        } else {
            LinearGradient.accentGradient
                .clipShape(Circle())
                .shadow(color: Color.accentPrimary.opacity(0.28), radius: 18, x: 0, y: 10)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = viewModel.todayPlan {
                let header = TodayPlanHeader.resolve(
                    planTitle: plan.title,
                    focus: plan.focus,
                    fallbackTitle: String(localized: "today.header.default_title")
                )
                let isPlanComplete = plan.totalSetsCount > 0 && plan.completedSetsCount >= plan.totalSetsCount

                HStack(spacing: 8) {
                    dateEyebrow(color: .accentPrimary)
                    if isPlanComplete {
                        completedChip
                    }
                }

                Text(header.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.textPrimary)

                if let subtitle = header.subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundColor(.textSecondary)
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
                    .padding(.top, 2)
                }
                if !viewModel.runningRecords.isEmpty {
                    Text(
                        LocalizedPlanText.todayRunningSummary(
                            distance: totalDistance.cleanDistance,
                            durationMinutes: totalDuration,
                            count: viewModel.runningRecords.count,
                            locale: locale
                        )
                    )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textSecondary)
                        .padding(.top, 2)
                }
            } else if viewModel.todayRecord != nil {
                dateEyebrow(color: .textMuted)
                Text("today.summary.free_record_day.title")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("today.summary.free_record_day.subtitle")
                    .font(.system(size: 15))
                    .foregroundColor(.textSecondary)
                if !viewModel.runningRecords.isEmpty {
                    Text(
                        LocalizedPlanText.todayRunningSummary(
                            distance: totalDistance.cleanDistance,
                            durationMinutes: totalDuration,
                            count: viewModel.runningRecords.count,
                            locale: locale
                        )
                    )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
            } else if !viewModel.runningRecords.isEmpty {
                dateEyebrow(color: .textMuted)
                Text("today.summary.running_only.title")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text(
                    LocalizedPlanText.todayRunningRecordsSummary(
                        distance: totalDistance.cleanDistance,
                        durationMinutes: totalDuration,
                        count: viewModel.runningRecords.count,
                        locale: locale
                    )
                )
                    .font(.system(size: 15))
                    .foregroundColor(.textMuted)
            } else {
                dateEyebrow(color: .textMuted)
                Text("today.summary.empty.title")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("today.summary.empty.subtitle")
                    .font(.system(size: 15))
                    .foregroundColor(.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    private func dateEyebrow(color: Color) -> some View {
        Text(TodayHeaderDateText.eyebrow(locale: locale))
            .font(.system(size: 12, weight: .semibold))
            .kerning(0.8)
            .foregroundColor(color)
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

    // MARK: - 计划动作区（浏览 / 专注共用同一 ForEach，卡片按模式切换形态）

    @ViewBuilder
    private var plannedSection: some View {
        if let plan = viewModel.todayPlan {
            VStack(alignment: .leading, spacing: isFocusMode ? 10 : 16) {
                let focusActive = isFocusMode
                let motionReduced = reduceMotion
                VStack(alignment: .leading, spacing: isFocusMode ? 10 : 16) {
                    ForEach(plan.exercises) { exercise in
                        exerciseCard(for: exercise)
                            .id(exercise.id)
                            .visualEffect { content, proxy in
                                // 距屏幕中心越远越小越淡；聚焦是连续函数，滑动过程自然过渡。
                                let containerHeight = proxy.bounds(of: .scrollView(axis: .vertical))?.height ?? 800
                                let midY = proxy.frame(in: .scrollView(axis: .vertical)).midY
                                let distance = min(abs(midY - containerHeight / 2) / max(containerHeight / 2, 1), 1)
                                let scale = focusActive && !motionReduced ? 1 - 0.04 * distance : 1
                                let opacity = focusActive ? 1 - 0.35 * distance : 1
                                return content
                                    .scaleEffect(scale)
                                    .opacity(opacity)
                            }
                    }
                }
                .scrollTargetLayout()
            }
        }
    }

    @ViewBuilder
    private func exerciseCard(for exercise: TrainingPlanExercise) -> some View {
        if isFocusMode, let session = viewModel.activeLiveWorkout {
            let liveModel = session.exercise(withId: exercise.id) ?? liveExercise(from: exercise)
            if displayedExerciseId == exercise.id {
                FocusExerciseCard(
                    exercise: liveModel,
                    session: session,
                    isCurrent: session.currentExercise?.id == exercise.id,
                    onToggleSet: { setId in
                        viewModel.toggleLiveSet(setId: setId)
                    },
                    onSkip: {
                        withAnimation(flowAnimation) {
                            viewModel.skipCurrentLiveExercise()
                        }
                    }
                )
                .transition(.opacity)
            } else {
                FocusCollapsedExerciseRow(
                    exercise: liveModel,
                    session: session,
                    onTap: {
                        withAnimation(flowAnimation) {
                            scrolledExerciseId = exercise.id
                            displayedExerciseId = exercise.id
                        }
                    }
                )
                .transition(.opacity)
            }
        } else {
            TodayPlannedExerciseCard(
                exercise: exercise,
                sessionCompletedSetIds: viewModel.activeLiveWorkout?.completedSetIds ?? [],
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
                onAddSet: {
                    Task { await viewModel.addPlannedSet(planExerciseId: exercise.id) }
                },
                onDeleteLastSet: {
                    Task { await viewModel.deleteLastPlannedSet(planExerciseId: exercise.id) }
                }
            )
        }
    }

    /// 计划在 session 开始后新增的动作不在 session 快照里，为展示构造一个只读镜像。
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

    @ViewBuilder
    private var recordedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // With a plan present, completed sets already show as checked-off plan rows;
            // the mirrored strength record would duplicate them, so only show it on free-record days.
            if viewModel.todayPlan == nil, let record = viewModel.todayRecord {
                sectionHeader(
                    title: String(localized: "today.section.strength_record.title"),
                    subtitle: String(localized: "today.section.strength_record.subtitle")
                )

                WorkoutRecordCard(
                    messageId: "today-record",
                    record: Binding(
                        get: { viewModel.todayRecord ?? record },
                        set: { viewModel.todayRecord = $0 }
                    ),
                    isEditable: true,
                    onDeleteExercise: { _ in },
                    onSetChanged: { exerciseId, updatedSet in
                        Task { await viewModel.updateLoggedSet(exerciseId: exerciseId, updatedSet: updatedSet) }
                    },
                    onAddSet: { exerciseId in
                        Task { await viewModel.addLoggedSet(exerciseId: exerciseId) }
                    },
                    onDeleteLastSet: { exerciseId in
                        Task { await viewModel.deleteLastLoggedSet(exerciseId: exerciseId) }
                    }
                )
            }

            if !viewModel.runningRecords.isEmpty {
                sectionHeader(
                    title: String(localized: "today.section.cardio_record.title"),
                    subtitle: String(localized: "today.section.cardio_record.subtitle")
                )

                ForEach(viewModel.runningRecords) { record in
                    RunningRecordCard(record: record)
                }
            }
        }
    }

    private var totalDuration: Int {
        viewModel.runningRecords.reduce(0) { $0 + $1.durationMinutes }
    }

    private var totalDistance: Double {
        viewModel.runningRecords.reduce(0) { $0 + $1.distanceKm }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                ForEach(exercise.sets) { set in
                    TodayPlannedSetRow(
                        set: set,
                        exerciseLoadType: exercise.exerciseLoadType,
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
    let exerciseLoadType: ExerciseLoadType
    let isCompletedInSession: Bool
    let onCommit: (Double?, WeightUnit, Int) -> Void
    let onToggleComplete: (Double?) -> Void
    @Environment(\.locale) private var locale

    @State private var editingWeight = false
    @State private var editingReps = false
    @State private var weightText = ""
    @State private var repsText = ""

    private var showsCompleted: Bool {
        self.set.isCompleted || isCompletedInSession
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(set.setIndex)")
                .font(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            Button {
                weightText = set.targetWeight.map(formatWeightValue) ?? ""
                editingWeight = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let weight = set.targetWeight {
                        Text(formatWeightValue(weight))
                            .font(.exerciseValue)
                            .foregroundColor(.accentValue)
                        Text(set.targetWeightUnit.display)
                            .font(.exerciseUnit)
                            .foregroundColor(.textSecondary)
                    } else {
                        Text(exerciseLoadLabel)
                            .font(.exerciseValue)
                            .foregroundColor(.accentValue)
                    }
                }
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
                repsText = "\(set.targetReps)"
                editingReps = true
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
            ValueEditSheet(
                title: String(localized: "chat.exercise.weight"),
                titleKey: "chat.exercise.edit_weight",
                unit: set.targetWeight == nil ? nil : set.targetWeightUnit.display,
                placeholder: exerciseLoadType.displayLabel,
                keyboardType: .decimalPad,
                value: $weightText
            ) {
                let trimmed = weightText.trimmingCharacters(in: .whitespacesAndNewlines)
                let weight = trimmed.isEmpty ? nil : Double(trimmed)
                onCommit(weight, set.targetWeightUnit, set.targetReps)
                editingWeight = false
            } onCancel: {
                editingWeight = false
            }
            .presentationDetents([.height(280)])
        }
        .sheet(isPresented: $editingReps) {
            ValueEditSheet(
                title: String(localized: "chat.exercise.reps"),
                titleKey: "chat.exercise.edit_reps",
                unit: String(localized: "chat.exercise.reps"),
                placeholder: "0",
                keyboardType: .numberPad,
                value: $repsText
            ) {
                if let reps = Int(repsText) {
                    onCommit(set.targetWeight, set.targetWeightUnit, reps)
                }
                editingReps = false
            } onCancel: {
                editingReps = false
            }
            .presentationDetents([.height(280)])
        }
    }

    private var exerciseLoadLabel: String {
        exerciseLoadType.displayLabel
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

#Preview {
    TodayWorkoutScreen(viewModel: TodayWorkoutViewModel())
}
