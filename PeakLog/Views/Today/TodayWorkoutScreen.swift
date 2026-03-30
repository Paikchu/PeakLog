import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TodayWorkoutScreen: View {
    @StateObject private var viewModel: TodayWorkoutViewModel

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
                        assistantReplyCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

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
        .background(Color.appBackground.ignoresSafeArea())
        .task { await viewModel.onAppear() }
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

            Text("AI 健身记录")
                .font(.headerTitle)
                .foregroundColor(.textPrimary)
                .tracking(-0.4)

            Spacer()

            Button { onShowProfile?() } label: {
                Image(systemName: "person.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.textPrimary)
                    .frame(width: 38, height: 38)
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

                Text("\(plan.completedSetsCount) / \(plan.totalSetsCount) sets completed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textMuted)

                progressBar(progress: plan.totalSetsCount == 0 ? 0 : Double(plan.completedSetsCount) / Double(plan.totalSetsCount))
            } else if viewModel.todayRecord != nil {
                Text("自由记录日")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("今天没有预设计划，你仍然可以直接记录训练内容。")
                    .font(.system(size: 15))
                    .foregroundColor(.textSecondary)
            } else {
                Text("休息日")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("今天没有训练计划。你可以通过底部输入框让 AI 帮你添加记录或调整计划。")
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
                sectionHeader(title: "AI 快捷建议", subtitle: "点一下即可复用到输入框")
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
                sectionHeader(title: "今日计划", subtitle: "直接勾选完成，或手动调整重量、次数、组数")

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
        if let record = viewModel.todayRecord {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "今日记录", subtitle: "AI 添加的动作和你手动记录的动作都可以继续编辑")

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
        }
    }

    @ViewBuilder
    private var assistantReplyCard: some View {
        if let reply = viewModel.latestAssistantReply, !reply.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title: "AI 结果", subtitle: nil)
                Text(reply)
                    .font(.chatBody)
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.appSurface)
                    .cornerRadius(AppRadius.xl)
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
    let onCommit: (Double?, WeightUnit, Int) -> Void
    let onToggleComplete: (Double?) -> Void

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
                        Text("chat.exercise.bodyweight")
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
                    Button("完成并记录 RPE \(value)") {
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
                unit: set.targetWeight == nil ? nil : set.targetWeightUnit.display,
                placeholder: String(localized: "chat.exercise.bodyweight"),
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
            .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $editingReps) {
            ValueEditSheet(
                title: String(localized: "chat.exercise.reps"),
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
            .presentationDetents([.height(220)])
        }
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
