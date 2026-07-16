import SwiftUI

struct PlannedCardioCard: View {
    let exercise: TrainingPlanExercise
    /// 未来日编辑模式隐藏"开始"入口——不能开始一个未来的有氧。
    var showsStartAction: Bool = true
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: activityType.iconName)
                    .appFont(size: 20, weight: .semibold)
                    .foregroundColor(.teal)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.teal.opacity(0.1)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(activityType.title)
                        .appFont(.exerciseName)
                        .foregroundColor(.textPrimary)
                    if let notes = exercise.notes, !notes.isEmpty {
                        Text(notes)
                            .appFont(size: 12)
                            .foregroundColor(.textMuted)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if exercise.isCardioCompleted {
                    Label("cardio.plan.completed", systemImage: "checkmark.circle.fill")
                        .appFont(size: 12, weight: .semibold)
                        .foregroundColor(.green)
                }
            }

            HStack(spacing: 8) {
                if let duration = exercise.targetDurationMinutes {
                    metric(String(localized: "cardio.metric.duration"), "\(duration) min")
                }
                if let distance = exercise.targetDistanceKm {
                    metric(String(localized: "cardio.metric.distance"), "\(distance.cleanDistance) km")
                }
            }

            if !exercise.isCardioCompleted && showsStartAction {
                Button(action: onStart) {
                    Label("cardio.plan.start", systemImage: "play.fill")
                        .appFont(size: 15, weight: .bold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.teal.opacity(0.16), lineWidth: 1)
        )
    }

    private var activityType: CardioActivityType {
        exercise.cardioActivityType ?? .running
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .appFont(size: 11, weight: .semibold)
                .foregroundColor(.textMuted)
            Text(value)
                .appFont(size: 15, weight: .bold, design: .rounded)
                .foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.teal.opacity(0.07))
        .cornerRadius(AppRadius.lg)
    }
}

extension CardioActivityType {
    var title: String {
        localizedTitle
    }

    var iconName: String {
        switch self {
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .elliptical: "figure.elliptical"
        case .stairClimber: "figure.stair.stepper"
        }
    }
}

private extension Double {
    var cleanDistance: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }
}
