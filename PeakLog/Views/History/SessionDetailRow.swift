import SwiftUI

struct SessionDetailRow: View {
    let session: WorkoutSession
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header
            sessionHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.accentPurple.opacity(0.15), Color.accentPurple.opacity(0.05)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            // Exercises
            VStack(spacing: 0) {
                ForEach(session.exercises) { exercise in
                    ExerciseDetailRow(exercise: exercise)
                    if exercise.id != session.exercises.last?.id {
                        Divider()
                            .background(Color.appSeparator)
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appSeparator, lineWidth: 0.5)
        )
    }

    // MARK: - Session Header
    private var sessionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 14))
                .foregroundColor(.accentPurple)

            if let label = session.label {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textPrimary)
            }

            if let minutes = session.durationMinutes {
                Text("•")
                    .foregroundColor(.textMuted)
                Text(
                    String(
                        format: String(localized: "history.session.minutes_format"),
                        locale: locale,
                        minutes
                    )
                )
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }

            Spacer()
        }
    }
}

// MARK: - Exercise Detail Row (within session)

private struct ExerciseDetailRow: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exercise.name)
                .font(.exerciseName)
                .foregroundColor(.textPrimary)

            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                HStack(spacing: 6) {
                    Text("#\(index + 1)")
                        .font(.setIndex)
                        .foregroundColor(.textDarkMuted)
                        .frame(width: 24, alignment: .leading)

                    Text("\(formatWeight(set.weight))\(set.weightUnit.display) × \(set.reps)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textSecondary)

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(w)) : String(format: "%.1f", w)
    }
}

#Preview {
    let session = WorkoutSession(
        id: "s-1",
        userId: "u-1",
        date: Date(),
        durationMinutes: 30,
        label: "Pull Day",
        exercises: [MockData.deadlift],
        createdAt: Date(),
        updatedAt: Date()
    )
    SessionDetailRow(session: session)
        .padding()
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
}
