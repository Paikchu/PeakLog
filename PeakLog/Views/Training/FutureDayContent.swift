import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 未来日期的内容区。计划周内与今日计划同一套卡片和交互——只是没有
/// 完成勾选（不能"完成"一个未来的组）和有氧开始按钮：
/// - 周内有安排："计划中"标记 + 可编辑计划卡（改目标/加减组/滑动删除/
///   长按重排）+ 虚线添加动作行；
/// - 周内休息日：占位文案 + 虚线添加动作行（添加后升级为训练日）；
/// - 计划周之外："计划尚未生成"占位，只读。
struct FutureDayContent: View {
    let tense: DayTense
    @ObservedObject var historyViewModel: HistoryViewModel
    @StateObject private var editor: FutureDayPlanEditorViewModel

    @State private var isPresentingAddExercise = false
    @State private var isReordering = false
    @State private var draftOrder: [TrainingPlanExercise] = []

    init(tense: DayTense, historyViewModel: HistoryViewModel) {
        self.tense = tense
        self.historyViewModel = historyViewModel
        _editor = StateObject(wrappedValue: FutureDayPlanEditorViewModel())
    }

    private var planDay: TrainingPlanDay? {
        historyViewModel.selectedPlanDay
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if tense == .futureBeyondPlan {
                    placeholder(
                        title: String(localized: "training.future.beyond_plan.title"),
                        subtitle: String(localized: "training.future.beyond_plan.subtitle")
                    )
                } else if let planDay, !planDay.exercises.isEmpty {
                    plannedChip
                    if isReordering {
                        ReorderableExerciseList(
                            items: $draftOrder,
                            sessionCompletedSetIds: [],
                            onCommit: { orderedIds in
                                Task {
                                    await editor.reorderExercises(
                                        orderedExerciseIds: orderedIds,
                                        on: historyViewModel.selectedDate
                                    )
                                }
                            },
                            onDone: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    isReordering = false
                                }
                            }
                        )
                        .transition(.opacity)
                    } else {
                        exerciseCards(for: planDay)
                    }
                    addExerciseRow
                } else {
                    placeholder(
                        title: String(localized: "training.future.rest_day.title"),
                        subtitle: String(localized: "training.future.rest_day.subtitle")
                    )
                    addExerciseRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 104)
        }
        .scrollDisabled(isReordering)
        .task {
            editor.onPlanChanged = { [weak historyViewModel] in
                await historyViewModel?.loadPlan()
            }
        }
        .sheet(isPresented: $isPresentingAddExercise) {
            AddPlanExerciseSheet { drafts in
                try await editor.addExercises(drafts, to: historyViewModel.selectedDate)
            }
        }
        .alert("common.error_title", isPresented: Binding(
            get: { editor.errorMessage != nil },
            set: { if !$0 { editor.errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
    }

    // MARK: - Exercise Cards (今日同款，无完成勾选)

    private func exerciseCards(for day: TrainingPlanDay) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(day.exercises) { exercise in
                SwipeToDeleteRow(onDelete: {
                    Task { await editor.deleteExercise(planExerciseId: exercise.id) }
                }) {
                    if exercise.itemType == .cardio {
                        PlannedCardioCard(exercise: exercise, showsStartAction: false) {}
                    } else {
                        TodayPlannedExerciseCard(
                            exercise: exercise,
                            sessionCompletedSetIds: [],
                            showsCompletionControl: false,
                            onUpdateSet: { setId, weight, unit, reps in
                                Task {
                                    await editor.updatePlannedSet(
                                        planSetId: setId,
                                        targetWeight: weight,
                                        targetWeightUnit: unit,
                                        targetReps: reps
                                    )
                                }
                            },
                            onCompleteSet: { _, _ in },
                            onAddSet: {
                                Task { await editor.addSet(to: exercise) }
                            },
                            onDeleteLastSet: {
                                Task { await editor.deleteLastSet(of: exercise) }
                            },
                            onLongPressHeader: {
                                draftOrder = day.exercises
#if canImport(UIKit)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    isReordering = true
                                }
                            }
                        )
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: day.exercises.map(\.id))
    }

    // MARK: - Add Row (与今日页同一文案与样式)

    private var addExerciseRow: some View {
        Button {
            isPresentingAddExercise = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .appFont(size: 15, weight: .bold)
                Text("today.add_menu.plan_exercise")
                    .appFont(size: 15, weight: .semibold)
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
        .accessibilityIdentifier("training.future.addPlanExercise")
    }

    private var plannedChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar.badge.clock")
                .appFont(size: 11, weight: .semibold)
            Text("training.future.planned_chip")
                .appFont(size: 12, weight: .semibold)
        }
        .foregroundColor(.accentPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentPrimary.opacity(0.1))
        .clipShape(Capsule())
    }

    private func placeholder(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .appFont(.rootPageTitle)
                .foregroundColor(.textPrimary)
            Text(subtitle)
                .appFont(size: 15)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 28)
    }
}
