import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 专注模式下的展开动作卡片

struct FocusExerciseCard: View {
    let exercise: PlanLiveWorkoutExercise
    let session: PlanLiveWorkoutSession
    let isCurrent: Bool
    let onToggleSet: (String) -> Void
    let onSkip: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isComplete: Bool {
        session.isExerciseComplete(exercise)
    }

    private var currentSetId: String? {
        guard isCurrent else { return nil }
        return session.currentSet?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            contextBlock

            VStack(spacing: 6) {
                ForEach(exercise.sets) { set in
                    FocusSetRow(
                        set: set,
                        loadType: exercise.loadType,
                        isCompleted: session.completedSetIds.contains(set.id),
                        isLocked: set.isAlreadyCompleted,
                        isCurrent: set.id == currentSetId,
                        onToggle: { onToggleSet(set.id) }
                    )
                }
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(
                    isCurrent ? Color.accentPrimary.opacity(0.55) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: currentSetId)
    }

    /// 训练中最需要盯着看的上下文：上次表现、教练建议、动作备注。
    /// 三者都缺时整块不渲染，卡片保持原有紧凑度。
    @ViewBuilder
    private var contextBlock: some View {
        let previous = exercise.previousPerformanceSummary?.trimmedNonEmpty
        let suggestion = exercise.aiSuggestion?.trimmedNonEmpty
        let notes = exercise.notes?.trimmedNonEmpty

        if previous != nil || suggestion != nil || notes != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let previous {
                    contextLine(
                        icon: "clock.arrow.circlepath",
                        prefix: String(localized: "training_session.context.last_time"),
                        text: previous,
                        tint: .textSecondary
                    )
                }
                if let suggestion {
                    contextLine(icon: "sparkles", prefix: nil, text: suggestion, tint: .accentPrimary.opacity(0.92))
                }
                if let notes {
                    contextLine(icon: "note.text", prefix: nil, text: notes, tint: .textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .fill(Color.workoutShell.opacity(0.7))
            )
            .accessibilityIdentifier("training_focus.context.\(exercise.id)")
        }
    }

    private func contextLine(icon: String, prefix: String?, text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .appFont(size: 11, weight: .semibold)
                .foregroundColor(tint.opacity(0.85))
                .frame(width: 14)

            Text(prefix.map { "\($0) \(text)" } ?? text)
                .appFont(size: 12.5, weight: .medium)
                .foregroundColor(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: AppRadius.full)
                .fill(isComplete ? Color.green : Color.accentPrimary)
                .frame(width: 5, height: 22)

            Text(exercise.name)
                .appFont(.exerciseName)
                .foregroundColor(.textPrimary)

            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .appFont(size: 16, weight: .semibold)
                    .foregroundColor(.green)
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            Text("\(session.completedSetsCount(in: exercise))/\(exercise.sets.count)")
                .appFont(size: 13, weight: .bold, design: .rounded)
                .foregroundColor(.textSecondary)

            if isCurrent, !isComplete {
                Menu {
                    Button(role: .destructive, action: onSkip) {
                        Label(String(localized: "training_session.skip_exercise"), systemImage: "arrow.uturn.forward")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundColor(.textMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .accessibilityIdentifier("training_focus.exerciseMenu.\(exercise.id)")
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - 专注模式下的组行（当前组放大高亮）

private struct FocusSetRow: View {
    let set: PlanLiveWorkoutSet
    let loadType: ExerciseLoadType
    let isCompleted: Bool
    /// 进入 session 前就已落库的组，不允许撤销。
    let isLocked: Bool
    let isCurrent: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isCurrent {
                RoundedRectangle(cornerRadius: AppRadius.full)
                    .fill(Color.accentPrimary)
                    .frame(width: 4, height: 30)
                    .transition(.opacity)
            }

            Text("\(set.setIndex)")
                .appFont(.setIndex)
                .foregroundColor(isCurrent ? .textPrimary : .textSecondary)
                .frame(width: isCurrent ? 34 : 28, height: isCurrent ? 34 : 28)
                .background(Circle().fill(Color.workoutIndexFill))

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let weight = set.targetWeight {
                    Text(formatWeightValue(weight))
                        .appFont(size: isCurrent ? 24 : 16, weight: .bold, design: .rounded)
                        .foregroundColor(isCompleted ? .textMuted : .accentValue)
                    Text(set.targetWeightUnit.display)
                        .appFont(.exerciseUnit)
                        .foregroundColor(.textSecondary)
                } else {
                    Text(loadType.displayLabel)
                        .appFont(size: isCurrent ? 20 : 15, weight: .bold, design: .rounded)
                        .foregroundColor(isCompleted ? .textMuted : .accentValue)
                }

                Text("×")
                    .appFont(.setIndex)
                    .foregroundColor(Color.accentBorder.opacity(0.55))

                Text("\(set.targetReps)")
                    .appFont(size: isCurrent ? 24 : 16, weight: .bold, design: .rounded)
                    .foregroundColor(isCompleted ? .textMuted : .accentValue)
                Text("chat.exercise.reps")
                    .appFont(.exerciseUnit)
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onToggle()
#if canImport(UIKit)
                if !isCompleted {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
#endif
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .appFont(size: isCurrent ? 24 : 20, weight: .semibold)
                    .foregroundColor(isCompleted ? .green : .textMuted)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(isLocked)
            .accessibilityIdentifier("training_focus.toggleSet.\(set.id)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isCurrent ? 10 : 5)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                .fill(isCurrent ? Color.workoutPanel : Color.workoutShell)
        )
        .opacity(isCompleted && !isCurrent ? 0.55 : 1)
    }
}

// MARK: - 专注模式下的折叠动作行

struct FocusCollapsedExerciseRow: View {
    let exercise: PlanLiveWorkoutExercise
    let session: PlanLiveWorkoutSession
    let onTap: () -> Void

    private var isComplete: Bool {
        session.isExerciseComplete(exercise)
    }

    private var isSkipped: Bool {
        session.skippedExerciseIds.contains(exercise.id) && !isComplete
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle.dotted")
                    .appFont(size: 17, weight: .semibold)
                    .foregroundColor(isComplete ? .green : .textMuted)

                Text(exercise.name)
                    .appFont(size: 15, weight: .semibold)
                    .foregroundColor(isComplete ? .textSecondary : .textPrimary)
                    .strikethrough(isComplete, color: .textMuted)

                if isSkipped {
                    Text("training_session.skipped")
                        .appFont(size: 11, weight: .bold)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                }

                Spacer()

                Text("\(session.completedSetsCount(in: exercise))/\(exercise.sets.count)")
                    .appFont(size: 13, weight: .bold, design: .rounded)
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Color.workoutShell.opacity(0.6))
        )
        .accessibilityIdentifier("training_focus.collapsed.\(exercise.id)")
    }
}

// MARK: - 底部确认栏（替代 dock）：完成当前组 / 休息倒计时 / 结束并保存

struct TrainingFocusBar: View {
    @ObservedObject var viewModel: TodayWorkoutViewModel
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if let session = viewModel.activeLiveWorkout {
                if session.isComplete {
                    finishButton
                } else if let restEndDate = viewModel.restEndDate, restEndDate > Date() {
                    restCountdown(until: restEndDate)
                } else {
                    completeSetButton(session)
                }
            }
        }
        .padding(.horizontal, BottomActionBarMetrics.horizontalPadding)
        .padding(.bottom, BottomActionBarMetrics.bottomPadding)
    }

    private func completeSetButton(_ session: PlanLiveWorkoutSession) -> some View {
        Button {
            viewModel.completeCurrentLiveSet()
#if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
        } label: {
            VStack(spacing: 2) {
                Text(LocalizedPlanText.formatted(
                    "training_session.complete_set",
                    locale: locale,
                    Int64(session.currentSet?.setIndex ?? 0)
                ))
                .appFont(size: 16, weight: .bold)

                if let set = session.currentSet {
                    Text(currentSetSummary(set, loadType: session.currentExercise?.loadType ?? .weighted))
                        .appFont(size: 12, weight: .medium)
                        .opacity(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .background(Color.accentPrimary.opacity(0.82), in: Capsule())
        .clipShape(Capsule())
        .accessibilityIdentifier("training_focus.completeSet")
    }

    private var finishButton: some View {
        Button {
            Task { await viewModel.confirmPlanLiveWorkout() }
#if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
        } label: {
            Label(String(localized: "training_session.all_done"), systemImage: "checkmark.seal.fill")
                .appFont(size: 16, weight: .bold)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .background(Color.green.opacity(0.82), in: Capsule())
        .clipShape(Capsule())
        .accessibilityIdentifier("training_focus.finishAll")
    }

    // 休息是训练里用户盯屏幕最久的时刻：倒计时放大、配剩余进度条，
    // 并预告接下来的组，休息结束前就知道该做什么。
    private func restCountdown(until endDate: Date) -> some View {
        let startDate = min(viewModel.restStartDate ?? endDate.addingTimeInterval(-TodayWorkoutViewModel.restDurationSeconds), endDate)

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundColor(.accentPrimary)

                Text("training_session.rest.title")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundColor(.textPrimary)

                Spacer()

                Button(action: { viewModel.extendRest() }) {
                    Text("training_session.rest.add_30s")
                        .appFont(size: 13, weight: .bold, design: .rounded)
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassChip(cornerRadius: AppRadius.full)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("training_focus.extendRest")

                Button(action: { viewModel.skipRest() }) {
                    Text("training_session.rest.skip")
                        .appFont(size: 13, weight: .bold)
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassChip(cornerRadius: AppRadius.full)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("training_focus.skipRest")
            }

            Text(timerInterval: Date()...endDate, countsDown: true)
                .monospacedDigit()
                .appFont(size: 44, weight: .bold, design: .rounded)
                .foregroundColor(.accentValue)
                .frame(maxWidth: .infinity, alignment: .center)

            ProgressView(timerInterval: startDate...endDate, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(Color.accentPrimary)

            if let nextUp = nextUpDescription {
                HStack(spacing: 6) {
                    Text("training_session.rest.next_up")
                        .appFont(size: 12, weight: .bold)
                        .foregroundColor(.textMuted)

                    Text(nextUp)
                        .appFont(size: 13, weight: .semibold, design: .rounded)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassPanel(cornerRadius: AppRadius.xxl)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous))
        .accessibilityIdentifier("training_focus.restPanel")
    }

    /// 休息结束后要做的组："卧推 · 第 3 组 · 60 kg × 8"。
    /// 完成一组时游标已流转到下一组，直接读当前指针即可。
    private var nextUpDescription: String? {
        guard let session = viewModel.activeLiveWorkout,
              let exercise = session.currentExercise,
              let set = session.currentSet else { return nil }
        let setLabel = LocalizedPlanText.formatted(
            "training_session.rest.set_n",
            locale: locale,
            Int64(set.setIndex)
        )
        return "\(exercise.name) · \(setLabel) · \(currentSetSummary(set, loadType: exercise.loadType))"
    }

    private func currentSetSummary(_ set: PlanLiveWorkoutSet, loadType: ExerciseLoadType) -> String {
        let load: String
        if let weight = set.targetWeight {
            load = "\(formatWeightValue(weight)) \(set.targetWeightUnit.display)"
        } else {
            load = loadType.displayLabel
        }
        return "\(load) × \(set.targetReps)"
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
