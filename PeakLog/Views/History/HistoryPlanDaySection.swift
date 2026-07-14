import SwiftUI

struct HistoryPlanDaySection: View {
    let day: TrainingPlanDay

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dayLabel)
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

    private var dayLabel: String {
        let formatter = WorkoutDateFormatter()
        if day.planDate == formatter.string(from: Date()) {
            return String(localized: "history.day.today")
        }
        guard let date = formatter.date(from: day.planDate) else {
            return day.planDate
        }
        return date.formatted(
            Date.FormatStyle()
                .locale(locale)
                .month(.abbreviated)
                .day()
                .weekday(.abbreviated)
        )
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
