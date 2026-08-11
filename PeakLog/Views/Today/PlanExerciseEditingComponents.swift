import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// 计划动作的编辑卡片与重排列表。今日计划与未来日编辑共用同一套组件：
// 今天带完成勾选（showsCompletionControl = true），未来日只编辑目标、
// 隐藏勾选圈与 RPE 完成菜单——"执行工具"和"编辑工具"的全部区别就是
// 这一个开关，用户不需要感知模式切换。

struct TodayPlannedExerciseCard: View {
    let exercise: TrainingPlanExercise
    /// 活跃 session 中已完成但尚未落库的组，用于浏览模式下同步显示勾选状态。
    let sessionCompletedSetIds: Set<String>
    var showsCompletionControl: Bool = true
    let onUpdateSet: (String, Double?, WeightUnit, Int) -> Void
    let onCompleteSet: (String, Double?) -> Void
    let onAddSet: () -> Void
    let onDeleteLastSet: () -> Void
    let onLongPressHeader: () -> Void
    /// 批量改本动作所有未完成组的目标。nil 表示宿主不提供批量入口，
    /// 组行的编辑面板就不出现那个开关。
    var onBatchUpdateSets: ((PlannedSetBatchAdjustment) -> Void)? = nil

    /// 只有还剩 2 组以上未完成时才值得出现批量开关——只剩一组时批量和单组
    /// 是同一件事。这里只数未完成组，因为批量写入本身也只改这些组：
    /// 开关的承诺要和实际写入的范围一致。
    private var batchHandlerForRows: ((PlannedSetBatchAdjustment) -> Void)? {
        guard exercise.sets.count(where: { !$0.isCompleted }) > 1 else { return nil }
        return onBatchUpdateSets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: AppRadius.full)
                        .fill(Color.accentPrimary)
                        .frame(width: 5, height: 22)

                    Text(exercise.exerciseName)
                        .appFont(.exerciseName)
                        .foregroundColor(.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    if let previous = exercise.previousPerformanceSummary, !previous.isEmpty {
                        Text(previous)
                            .appFont(size: 12, weight: .medium)
                            .foregroundColor(.textMuted)
                    }
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.4, perform: onLongPressHeader)

                Spacer()

                if exercise.sets.count > 1 {
                    Button(action: onDeleteLastSet) {
                        Image(systemName: "minus.circle")
                            .appFont(size: 16, weight: .semibold)
                            .foregroundColor(.textMuted)
                    }
                }

                Button(action: onAddSet) {
                    Image(systemName: "plus.circle.fill")
                        .appFont(size: 17, weight: .semibold)
                        .foregroundColor(.accentPrimary)
                }
            }
            if let suggestion = exercise.aiSuggestion, !suggestion.isEmpty {
                Text(suggestion)
                    .appFont(size: 12)
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
                        showsCompletionControl: showsCompletionControl,
                        onCommit: { weight, unit, reps in
                            onUpdateSet(set.id, weight, unit, reps)
                        },
                        onToggleComplete: { rpe in
                            onCompleteSet(set.id, rpe)
                        },
                        onBatchCommit: batchHandlerForRows
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

struct TodayPlannedSetRow: View {
    let set: TrainingPlanSet
    let exerciseId: String?
    let exerciseName: String
    let exerciseLoadType: ExerciseLoadType
    let precedingSet: TrainingPlanSet?
    let isCompletedInSession: Bool
    var showsCompletionControl: Bool = true
    let onCommit: (Double?, WeightUnit, Int) -> Void
    let onToggleComplete: (Double?) -> Void
    /// 非 nil 时编辑面板出现「应用到所有未完成组」开关；勾选后「完成」提交的是
    /// 一次批量调节，而不是这一组的单独修改。
    var onBatchCommit: ((PlannedSetBatchAdjustment) -> Void)? = nil
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

    /// 已完成组的面板不给批量开关：批量写入本身跳过已完成组，勾了却连当前这组
    /// 都不变，只会让人以为功能没生效。
    private var batchCommitHandler: ((PlannedSetBatchAdjustment) -> Void)? {
        self.set.isCompleted ? nil : onBatchCommit
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(set.setIndex)")
                .appFont(.setIndex)
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
                .appFont(.setIndex)
                .foregroundColor(Color.accentBorder.opacity(0.55))

            Button {
                presentRepsEditor()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(set.targetReps)")
                        .appFont(.exerciseValue)
                        .foregroundColor(.accentValue)
                    Text("chat.exercise.reps")
                        .appFont(.exerciseUnit)
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel)
                )
            }

            if showsCompletionControl {
                Button(action: {
                    onToggleComplete(nil)
#if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
                }) {
                    Image(systemName: showsCompleted ? "checkmark.circle.fill" : "circle")
                        .appFont(size: 21, weight: .semibold)
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
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $editingWeight) {
            // 显式标注类型，让 map 出来的这层闭包不依赖推断；同时批量分支只在
            // onBatchCommit 存在时才构造，面板据此决定要不要显示开关。
            let batchHandler: ((Double?) -> Void)? = batchCommitHandler.map { commit in
                { weight in
                    commit(PlannedSetBatchAdjustment(weight: .uniform(weight, unit: set.targetWeightUnit)))
                    editingWeight = false
                }
            }
            WeightWheelEditSheet(
                allowsBodyweightToggle: allowsBodyweightToggle,
                weightUnit: set.targetWeightUnit,
                initialWeight: set.targetWeight,
                lastTime: weightSuggestion,
                onDone: { weight in
                    onCommit(weight, set.targetWeightUnit, set.targetReps)
                    editingWeight = false
                },
                onCancel: {
                    editingWeight = false
                },
                onDoneApplyingToAllSets: batchHandler
            )
            .presentationDetents([.height(weightSheetHeight)])
        }
        .sheet(isPresented: $editingReps) {
            let batchHandler: ((Int) -> Void)? = batchCommitHandler.map { commit in
                { reps in
                    commit(PlannedSetBatchAdjustment(reps: .uniform(reps)))
                    editingReps = false
                }
            }
            RepsWheelEditSheet(
                initialReps: set.targetReps,
                lastTime: repsSuggestion,
                onDone: { reps in
                    onCommit(set.targetWeight, set.targetWeightUnit, reps)
                    editingReps = false
                },
                onCancel: {
                    editingReps = false
                },
                onDoneApplyingToAllSets: batchHandler
            )
            .presentationDetents([.height(repsSheetHeight)])
        }
    }

    /// 多出来的一行开关要占高度，否则轮盘或按钮会被挤出可见区。
    private var weightSheetHeight: CGFloat {
        let base: CGFloat = allowsBodyweightToggle ? 420 : 380
        return batchCommitHandler == nil ? base : base + 52
    }

    private var repsSheetHeight: CGFloat {
        batchCommitHandler == nil ? 360 : 412
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

struct ReorderableExerciseList: View {
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
                    .appFont(size: 15, weight: .semibold)
                    .foregroundColor(.textSecondary)
                Spacer()
                Button(action: onDone) {
                    Text("common.done")
                        .appFont(size: 15, weight: .bold)
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

struct ReorderableExerciseRow: View {
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
                .appFont(size: 15, weight: .semibold)
                .foregroundColor(.textPrimary)
                .lineLimit(1)

            Spacer()

            Text(LocalizedPlanText.formatted(
                "today.plan.reorder.sets_badge",
                locale: locale,
                Int64(completedSets),
                Int64(totalSets)
            ))
                .appFont(size: 13, weight: .semibold, design: .rounded)
                .foregroundColor(.textSecondary)

            Image(systemName: "line.3.horizontal")
                .appFont(size: 15, weight: .semibold)
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
