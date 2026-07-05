import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TodayWorkoutScreen: View {
    @StateObject private var viewModel: TodayWorkoutViewModel
    @State private var isPresentingDailyRecord = false
    @State private var isPresentingAddPlanExercise = false
    @Environment(\.locale) private var locale

    init() {
        _viewModel = StateObject(wrappedValue: TodayWorkoutViewModel())
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 18) {
                        if viewModel.isLoading {
                            ProgressView().padding(.top, 40)
                        } else {
                            summaryCard
                            plannedSection
                            recordedSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 104)
                }
                .dismissKeyboardOnTap()
            }

            addRecordButton
                .padding(.trailing, 20)
                .padding(.bottom, 22)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .dismissKeyboardOnTap()
        .task { await viewModel.onAppear() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            viewModel.syncLiveActivityCompletions()
        }
        .sheet(isPresented: $isPresentingDailyRecord) {
            DailyRecordSheet { draft in
                await viewModel.addDailyRecord(draft)
            }
        }
        .sheet(isPresented: $isPresentingAddPlanExercise) {
            AddPlanExerciseSheet { draft in
                await viewModel.addPlanExercise(
                    name: draft.exerciseName,
                    loadType: draft.loadType,
                    targetWeight: draft.targetWeight,
                    targetWeightUnit: draft.targetWeightUnit,
                    targetReps: draft.targetReps,
                    setsCount: draft.setsCount
                )
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.activeLiveWorkout != nil },
            set: { if !$0 { viewModel.cancelPlanLiveWorkout() } }
        )) {
            TrainingSessionScreen(viewModel: viewModel)
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
            Text("today.header.title")
                .font(.headerTitle)
                .foregroundColor(.textPrimary)
                .tracking(-0.4)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
                .fill(Color.accentPurple.opacity(0.32))
                .glassEffect(.regular.tint(Color.accentPurple.opacity(0.25)).interactive(), in: .rect(cornerRadius: 29))
                .shadow(color: Color.accentPurple.opacity(0.24), radius: 18, x: 0, y: 10)
        } else {
            LinearGradient.accentGradient
                .clipShape(Circle())
                .shadow(color: Color.accentPurple.opacity(0.28), radius: 18, x: 0, y: 10)
        }
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

                PlanProgressBar(progress: plan.totalSetsCount == 0 ? 0 : Double(plan.completedSetsCount) / Double(plan.totalSetsCount))
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

                startPlanButton
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
        .glassPanel(cornerRadius: AppRadius.xxl)
    }

    @ViewBuilder
    private var startPlanButton: some View {
        if (viewModel.todayPlan?.totalSetsCount ?? 0) > 0 {
            Button {
                viewModel.startPlanLiveWorkout()
            } label: {
                Label("开始训练", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .glassActionBackground(cornerRadius: AppRadius.xl, tint: Color.accentPurple.opacity(0.42))
            .disabled(viewModel.isSending || viewModel.activeLiveWorkout != nil)
            .accessibilityIdentifier("today.startPlan")
            .padding(.top, 8)
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
        .glassPanel(cornerRadius: AppRadius.xl)
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

struct PlanProgressBar: View {
    let progress: Double

    var body: some View {
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
    TodayWorkoutScreen()
}
