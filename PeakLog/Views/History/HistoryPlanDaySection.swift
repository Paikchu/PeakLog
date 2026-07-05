import SwiftUI

struct HistoryPlanDaySection: View {
    let day: TrainingPlanDay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(day.planDate == WorkoutDateFormatter().string(from: Date()) ? String(localized: "Today") : day.planDate)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.textMuted)

            Text(day.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.textPrimary)

            if let focus = day.focus, !focus.isEmpty {
                Text(focus)
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }

            ForEach(day.exercises) { exercise in
                VStack(alignment: .leading, spacing: 8) {
                    Text(exercise.exerciseName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.textPrimary)

                    ForEach(exercise.sets) { set in
                        Text(setDisplayText(set, loadType: exercise.exerciseLoadType))
                            .font(.system(size: 13))
                            .foregroundColor(.textSecondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setDisplayText(_ set: TrainingPlanSet, loadType: ExerciseLoadType) -> String {
        if let weight = set.targetWeight {
            return "\(weight.clean) \(set.targetWeightUnit.display) × \(set.targetReps)"
        }
        return "\(loadType.displayLabel) × \(set.targetReps)"
    }
}

private extension Double {
    var clean: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }
}
