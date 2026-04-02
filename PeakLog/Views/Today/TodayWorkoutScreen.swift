import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TodayWorkoutScreen: View {
    @StateObject private var viewModel: TodayWorkoutViewModel
    @State private var isPresentingManualEntry = false
    private let chatScrollKeyboardDismissBehavior = ChatScrollKeyboardDismissBehavior()
    @Environment(\.locale) private var locale

    var onShowHistory: (() -> Void)?
    var onShowProfile: (() -> Void)?

    init(
        onShowHistory: (() -> Void)? = nil,
        onShowProfile: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: TodayWorkoutViewModel())
        self.onShowHistory = onShowHistory
        self.onShowProfile = onShowProfile
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 18) {
                        if viewModel.isLoading {
                            ProgressView().padding(.top, 40)
                        } else {
                            summaryCard
                            quickActionsSection
                            plannedSection
                            recordedSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .dismissKeyboardOnTap()
                .chatScrollDismissesKeyboard(chatScrollKeyboardDismissBehavior)

                ChatInputBar(
                    text: $viewModel.inputText,
                    isSending: viewModel.isSending,
                    voiceState: viewModel.voiceInputState
                ) {
                    Task { await viewModel.sendAction() }
                } onVoiceToggle: {
                    Task { await viewModel.toggleVoiceInput() }
                }
            }

            if viewModel.isOverlayVisible {
                TodayAIFloatingOverlay(
                    phase: viewModel.overlayPhase,
                    reply: viewModel.streamingReply,
                    blocks: viewModel.overlayContentBlocks,
                    didPersistPlan: viewModel.didPersistPlan,
                    onClose: viewModel.dismissOverlay
                )
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .dismissKeyboardOnTap()
        .task { await viewModel.onAppear() }
        .sheet(isPresented: $isPresentingManualEntry) {
            ManualRunningEntrySheet { durationMinutes, distanceKm in
                Task {
                    await viewModel.addRunningRecord(durationMinutes: durationMinutes, distanceKm: distanceKm)
                }
            }
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

    private var header: some View {
        HStack {
            Button { onShowHistory?() } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 20))
                    .foregroundColor(.textPrimary)
                    .frame(width: 38, height: 38)
            }

            Spacer()

            Text("today.header.title")
                .font(.headerTitle)
                .foregroundColor(.textPrimary)
                .tracking(-0.4)

            Spacer()

            HStack(spacing: 6) {
                Button {
                    isPresentingManualEntry = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.textPrimary)
                        .frame(width: 38, height: 38)
                }

                Button { onShowProfile?() } label: {
                    Image(systemName: "person.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.textPrimary)
                        .frame(width: 38, height: 38)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.textMuted)

            if let plan = viewModel.todayPlan {
                Text(plan.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.textPrimary)

                if let focus = plan.focus, !focus.isEmpty {
                    Text(focus)
                        .font(.system(size: 15))
                        .foregroundColor(.textSecondary)
                }

                Text(LocalizedPlanText.setsCompleted(completed: plan.completedSetsCount, total: plan.totalSetsCount, locale: locale))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textMuted)

                progressBar(progress: plan.totalSetsCount == 0 ? 0 : Double(plan.completedSetsCount) / Double(plan.totalSetsCount))
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
                Text("today.summary.empty.title")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("today.summary.empty.subtitle")
                    .font(.system(size: 15))
                    .foregroundColor(.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xxl)
    }

    @ViewBuilder
    private var quickActionsSection: some View {
        if !viewModel.quickActions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    title: String(localized: "today.section.quick_actions.title"),
                    subtitle: String(localized: "today.section.quick_actions.subtitle")
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.quickActions) { action in
                            Button {
                                viewModel.inputText = action.prompt
                            } label: {
                                Text(action.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.workoutPanel)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var plannedSection: some View {
        if let plan = viewModel.todayPlan {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: String(localized: "today.section.plan.title"),
                    subtitle: String(localized: "today.section.plan.subtitle")
                )

                ForEach(plan.exercises) { exercise in
                    TodayPlannedExerciseCard(
                        exercise: exercise,
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
        }
    }

    @ViewBuilder
    private var recordedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let record = viewModel.todayRecord {
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

private struct ManualRunningEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var durationText = ""
    @State private var distanceText = ""

    let onSave: (Int, Double) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("today.manual_running.duration_section") {
                    TextField(String(localized: "today.manual_running.duration_placeholder"), text: $durationText)
                        .keyboardType(.numberPad)
                }

                Section("today.manual_running.distance_section") {
                    TextField(String(localized: "today.manual_running.distance_placeholder"), text: $distanceText)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("today.manual_running.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("today.manual_running.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("today.manual_running.save") {
                        guard let duration = Int(durationText), let distance = Double(distanceText) else { return }
                        onSave(duration, distance)
                        dismiss()
                    }
                    .disabled(Int(durationText) == nil || Double(distanceText) == nil)
                }
            }
        }
    }
}

private struct TodayAIFloatingOverlay: View {
    let phase: TodayAIOverlayPhase
    let reply: String
    let blocks: [ContentBlock]
    let didPersistPlan: Bool
    let onClose: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(statusColor.opacity(0.9))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text(statusSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
            }

            if !reply.isEmpty {
                Text(reply)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.xl)
                            .fill(Color.white.opacity(0.12))
                    )
            }

            if !blocks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .weeklyPlan(let plan):
                            overlayWeeklyPlanCard(plan)
                        case .todayPlan(let plan):
                            overlayTodayPlanCard(plan)
                        case .planAdjustmentSummary(let summary):
                            Text(summary.summaryText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.86))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(12)
                        default:
                            EmptyView()
                        }
                    }
                }
            }

            if didPersistPlan {
                Text("today.overlay.plan_persisted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.82))
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.15, green: 0.34, blue: 0.78).opacity(0.88),
                            Color(red: 0.09, green: 0.18, blue: 0.44).opacity(0.84),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
    }

    private var statusColor: Color {
        switch phase {
        case .idle:
            return .white
        case .processing:
            return Color(red: 0.50, green: 0.84, blue: 1.0)
        case .applying:
            return Color(red: 0.84, green: 0.92, blue: 1.0)
        case .completed:
            return Color.green.opacity(0.9)
        case .failed:
            return Color.red.opacity(0.9)
        }
    }

    private var statusTitle: String {
        let isPlanFlow = didPersistPlan || !blocks.isEmpty
        switch phase {
        case .idle:
            return String(localized: "today.overlay.status.idle.title")
        case .processing:
            return String(localized: "today.overlay.status.processing.title")
        case .applying:
            return String(localized: isPlanFlow ? "today.overlay.status.applying_plan.title" : "today.overlay.status.applying_record.title")
        case .completed:
            return String(localized: isPlanFlow ? "today.overlay.status.completed_plan.title" : "today.overlay.status.completed_record.title")
        case .failed:
            return String(localized: "today.overlay.status.failed.title")
        }
    }

    private var statusSubtitle: String {
        let isPlanFlow = didPersistPlan || !blocks.isEmpty
        switch phase {
        case .idle:
            return String(localized: "today.overlay.status.idle.subtitle")
        case .processing:
            return String(localized: "today.overlay.status.processing.subtitle")
        case .applying:
            return String(localized: isPlanFlow ? "today.overlay.status.applying_plan.subtitle" : "today.overlay.status.applying_record.subtitle")
        case .completed:
            return String(localized: isPlanFlow ? "today.overlay.status.completed_plan.subtitle" : "today.overlay.status.completed_record.subtitle")
        case .failed:
            return String(localized: "today.overlay.status.failed.subtitle")
        }
    }

    private func overlayWeeklyPlanCard(_ plan: WeeklyPlanBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("today.overlay.weekly_plan.title")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.88))
            Text(LocalizedPlanText.weekOf(plan.weekStartDate, locale: locale))
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            ForEach(plan.days.prefix(7)) { day in
                HStack(spacing: 10) {
                    Text(LocalizedPlanText.weekdayLabel(dayIndex: day.dayIndex, locale: locale))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))
                        if let focus = day.focus, !focus.isEmpty {
                            Text(focus)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.72))
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.10))
        .cornerRadius(18)
    }

    private func overlayTodayPlanCard(_ plan: TodayPlanBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("today.overlay.today_changes.title")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.88))
            Text(plan.day.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            if let focus = plan.day.focus, !focus.isEmpty {
                Text(focus)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.76))
            }
            if !plan.day.exercises.isEmpty {
                Text(plan.day.exercises.map(\.exerciseName).joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.10))
        .cornerRadius(18)
    }
}

private struct TodayPlannedExerciseCard: View {
    let exercise: TrainingPlanExercise
    let onUpdateSet: (String, Double?, WeightUnit, Int) -> Void
    let onCompleteSet: (String, Double?) -> Void
    let onAddSet: () -> Void
    let onDeleteLastSet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: AppRadius.full)
                    .fill(Color.accentPurple)
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
                        .foregroundColor(.accentPurple)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xxl)
                    .fill(Color.workoutPanel.opacity(0.5))
            )

            if let suggestion = exercise.aiSuggestion, !suggestion.isEmpty {
                Text(suggestion)
                    .font(.system(size: 12))
                    .foregroundColor(.accentPurple.opacity(0.92))
                    .padding(.horizontal, 14)
            }

            VStack(spacing: 6) {
                ForEach(exercise.sets) { set in
                    TodayPlannedSetRow(
                        set: set,
                        exerciseLoadType: exercise.exerciseLoadType,
                        onCommit: { weight, unit, reps in
                            onUpdateSet(set.id, weight, unit, reps)
                        },
                        onToggleComplete: { rpe in
                            onCompleteSet(set.id, rpe)
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .padding(8)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.accentPurple.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct TodayPlannedSetRow: View {
    let set: TrainingPlanSet
    let exerciseLoadType: ExerciseLoadType
    let onCommit: (Double?, WeightUnit, Int) -> Void
    let onToggleComplete: (Double?) -> Void
    @Environment(\.locale) private var locale

    @State private var editingWeight = false
    @State private var editingReps = false
    @State private var weightText = ""
    @State private var repsText = ""

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
                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(set.isCompleted ? .green : .textMuted)
            }
            .disabled(set.isCompleted)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.workoutShell)
        )
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

private extension TodayWorkoutScreen {
    func progressBar(progress: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentPurple, Color.green.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(proxy.size.width * progress, progress > 0 ? 18 : 0))
            }
        }
        .frame(height: 8)
    }
}

#Preview {
    TodayWorkoutScreen()
}
