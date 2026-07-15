import SwiftUI

struct HistoryCompletedTrainingSection: View {
    let summary: CompletedDaySummary
    let strengthExercises: [CompletedStrengthExerciseViewData]
    let cardioRecords: [CompletedCardioRecordViewData]
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 12) {
            if !strengthExercises.isEmpty {
                sectionHeader(
                    String(localized: "history.completed.strength.title"),
                    subtitle: LocalizedPlanText.historyStrengthSectionSubtitle(
                        exerciseCount: strengthExercises.count,
                        setCount: summary.strengthSetCount,
                        locale: locale
                    )
                )

                ForEach(strengthExercises) { exercise in
                    HistoryCompletedStrengthExerciseCard(exercise: exercise)
                }
            }

            if !cardioRecords.isEmpty {
                sectionHeader(
                    String(localized: "history.completed.cardio.title"),
                    subtitle: LocalizedPlanText.historyCardioSectionSubtitle(
                        recordCount: cardioRecords.count,
                        locale: locale
                    )
                )

                ForEach(cardioRecords) { record in
                    HistoryCompletedCardioRecordCard(record: record)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(size: 17, weight: .bold)
                .foregroundColor(.textPrimary)
            Text(subtitle)
                .appFont(size: 12, weight: .medium)
                .foregroundColor(.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

struct HistoryCompletedStrengthExerciseCard: View {
    let exercise: CompletedStrengthExerciseViewData
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: AppRadius.full)
                    .fill(Color.accentPrimary)
                    .frame(width: 5, height: 22)

                Text(exercise.name)
                    .appFont(.exerciseName)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Spacer()

                Text(LocalizedPlanText.completedStrengthBadge(exercise.completedSetCount, locale: locale))
                    .appFont(size: 12, weight: .semibold)
                    .foregroundColor(.green.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xxl)
                    .fill(Color.workoutPanel.opacity(0.5))
            )

            VStack(spacing: 6) {
                ForEach(exercise.sets) { set in
                    HistoryCompletedStrengthSetRow(set: set)
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
                .strokeBorder(Color.accentPrimary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct HistoryCompletedStrengthSetRow: View {
    let set: CompletedStrengthSetViewData
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 14) {
            Text("\(set.setIndex)")
                .appFont(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            infoChip(loadText, accentColor: loadTint)

            Text("×")
                .appFont(.setIndex)
                .foregroundColor(Color.accentBorder.opacity(0.55))

            infoChip(
                LocalizedPlanText.formatted("history.completed.reps_value", locale: locale, Int64(set.reps)),
                accentColor: .accentPrimary
            )

            Spacer(minLength: 4)

            if let rpe = set.rpe {
                Text("RPE \(rpe.cleanRPE)")
                    .appFont(size: 11, weight: .medium)
                    .foregroundColor(.textMuted)
            }

            Image(systemName: "checkmark.circle.fill")
                .appFont(size: 21, weight: .semibold)
                .foregroundColor(.green)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.workoutShell)
        )
    }

    private var loadText: String {
        switch set.loadDisplay {
        case let .weighted(weight, unit):
            return "\(formatWeightValue(weight)) \(unit.display)"
        case .bodyweight:
            return String(localized: "chat.exercise.bodyweight")
        case let .bodyweightWithAdded(weight, unit):
            return LoadDisplayFormat.plainText(weight: weight, unit: unit, isBodyweight: true)
        case .unrecordedWeight:
            return String(localized: "history.completed.unrecorded_weight")
        }
    }

    private var loadTint: Color {
        switch set.loadDisplay {
        case .weighted, .bodyweightWithAdded:
            return .accentPrimary
        case .bodyweight:
            return .green
        case .unrecordedWeight:
            return .orange
        }
    }

    private func infoChip(_ text: String, accentColor: Color) -> some View {
        Text(text)
            .appFont(size: 14, weight: .semibold)
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .fill(accentColor.opacity(0.08))
            )
    }
}

struct HistoryCompletedCardioRecordCard: View {
    let record: CompletedCardioRecordViewData
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: AppRadius.full)
                    .fill(Color.teal)
                    .frame(width: 5, height: 22)

                Text(record.title)
                    .appFont(.exerciseName)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Spacer()

                Text(sourceLabel)
                    .appFont(size: 12, weight: .semibold)
                    .foregroundColor(.teal.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.teal.opacity(0.08))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xxl)
                    .fill(Color.workoutPanel.opacity(0.42))
            )

            HStack(spacing: 8) {
                metricChip(
                    title: String(localized: "history.completed.metric.distance"),
                    value: LocalizedPlanText.historyMetricDistance(record.distanceKm.cleanDistance, locale: locale)
                )
                metricChip(
                    title: String(localized: "history.completed.metric.duration"),
                    value: LocalizedPlanText.historyMetricDuration(record.durationMinutes, locale: locale)
                )
                if let paceText = record.paceText {
                    metricChip(title: String(localized: "history.completed.metric.pace"), value: paceText)
                }
            }

            Text(dateLabel)
                .appFont(size: 12)
                .foregroundColor(.textMuted)
        }
        .padding(14)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.teal.opacity(0.12), lineWidth: 1)
        )
    }

    private var sourceLabel: String {
        switch record.source {
        case .agent:
            return String(localized: "history.completed.source.ai")
        case .manual:
            return String(localized: "history.completed.source.manual")
        }
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: record.createdAt)
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(size: 11, weight: .semibold)
                .foregroundColor(.textMuted)
            Text(value)
                .appFont(size: 15, weight: .bold)
                .foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.teal.opacity(0.07))
        .cornerRadius(AppRadius.lg)
    }
}

private extension Double {
    var cleanDistance: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }

    var cleanRPE: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }
}
