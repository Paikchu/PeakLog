import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TrainingSessionScreen: View {
    @ObservedObject var viewModel: TodayWorkoutViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if let session = viewModel.activeLiveWorkout {
                    VStack(spacing: 0) {
                        header(session)

                        ScrollView {
                            VStack(spacing: 12) {
                                ForEach(session.exercises) { exercise in
                                    TrainingSessionExerciseCard(
                                        exercise: exercise,
                                        completedSetIds: session.completedSetIds,
                                        onToggleSet: { setId in
                                            viewModel.toggleLiveSet(setId: setId)
                                        }
                                    )
                                }
                            }
                            .padding(16)
                            .padding(.bottom, 100)
                        }

                        footer(session)
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            viewModel.syncLiveActivityCompletions()
        }
    }

    private func header(_ session: PlanLiveWorkoutSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    viewModel.cancelPlanLiveWorkout()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 34, height: 34)
                        .glassChip(cornerRadius: AppRadius.full)
                }

                Spacer()

                Text("\(session.completedSetsCount)/\(session.totalSetsCount)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassChip(cornerRadius: AppRadius.full)
            }

            Text(session.title)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.textPrimary)

            PlanProgressBar(progress: session.progress)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func footer(_ session: PlanLiveWorkoutSession) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.cancelPlanLiveWorkout()
            } label: {
                Text("training_session.cancel")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
            .foregroundColor(.textPrimary)
            .glassActionBackground(cornerRadius: AppRadius.xl, tint: Color.white.opacity(0.12))

            Button {
                Task { await viewModel.confirmPlanLiveWorkout() }
            } label: {
                Text("training_session.finish")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .glassActionBackground(cornerRadius: AppRadius.xl, tint: Color.accentPrimary.opacity(0.42))
            .disabled(session.completedSetsCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .background(.ultraThinMaterial)
    }
}

private struct TrainingSessionExerciseCard: View {
    let exercise: PlanLiveWorkoutExercise
    let completedSetIds: Set<String>
    let onToggleSet: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: AppRadius.full)
                    .fill(Color.accentPrimary)
                    .frame(width: 5, height: 22)

                Text(exercise.name)
                    .font(.exerciseName)
                    .foregroundColor(.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 6) {
                ForEach(exercise.sets) { set in
                    TrainingSessionSetRow(
                        set: set,
                        loadType: exercise.loadType,
                        isCompleted: completedSetIds.contains(set.id),
                        onToggle: { onToggleSet(set.id) }
                    )
                }
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: AppRadius.xl)
    }
}

private struct TrainingSessionSetRow: View {
    let set: PlanLiveWorkoutSet
    let loadType: ExerciseLoadType
    let isCompleted: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("\(set.setIndex)")
                .font(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let weight = set.targetWeight {
                    Text(formatWeightValue(weight))
                        .font(.exerciseValue)
                        .foregroundColor(.accentValue)
                    Text(set.targetWeightUnit.display)
                        .font(.exerciseUnit)
                        .foregroundColor(.textSecondary)
                } else {
                    Text(loadType.displayLabel)
                        .font(.exerciseValue)
                        .foregroundColor(.accentValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("×")
                .font(.setIndex)
                .foregroundColor(Color.accentBorder.opacity(0.55))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(set.targetReps)")
                    .font(.exerciseValue)
                    .foregroundColor(.accentValue)
                Text("chat.exercise.reps")
                    .font(.exerciseUnit)
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onToggle()
#if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isCompleted ? .green : .textMuted)
            }
            .accessibilityIdentifier("training_session.toggleSet.\(set.id)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.workoutShell)
        )
    }
}
