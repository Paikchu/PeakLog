import SwiftUI

struct HistoryCompletedTrainingSection: View {
    let summary: CompletedDaySummary
    let strengthExercises: [CompletedStrengthExerciseViewData]
    let cardioRecords: [CompletedCardioRecordViewData]
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 12) {
            HistoryCompletedDaySummaryCard(summary: summary)

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
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.textPrimary)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

struct HistoryCompletedDaySummaryCard: View {
    let summary: CompletedDaySummary
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("history.completed.day.title")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.textMuted)

            Text(dayLabel)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.textPrimary)

            Text(summaryLine)
                .font(.system(size: 14))
                .foregroundColor(.textSecondary)

            HStack(spacing: 10) {
                summaryChip(
                    title: String(localized: "history.completed.summary.strength"),
                    value: LocalizedPlanText.completedStrengthValue(summary.strengthExerciseCount, locale: locale),
                    tint: .accentPrimary
                )
                summaryChip(
                    title: String(localized: "history.completed.summary.sets"),
                    value: LocalizedPlanText.completedSetValue(summary.strengthSetCount, locale: locale),
                    tint: .green
                )
                if summary.cardioRecordCount > 0 {
                    summaryChip(
                        title: String(localized: "history.completed.summary.cardio"),
                        value: LocalizedPlanText.completedCardioValue(summary.cardioRecordCount, locale: locale),
                        tint: .teal
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appSeparator, lineWidth: 0.5)
        )
    }

    private var dayLabel: String {
        summary.date.formatted(
            Date.FormatStyle()
                .locale(locale)
                .month(.abbreviated)
                .day()
        )
    }

    private var summaryLine: String {
        var parts: [String] = []
        if summary.strengthExerciseCount > 0 {
            parts.append(LocalizedPlanText.completedStrengthLine(summary.strengthExerciseCount, locale: locale))
        }
        if summary.cardioRecordCount > 0 {
            parts.append(LocalizedPlanText.completedCardioLine(summary.cardioRecordCount, locale: locale))
        }
        if summary.totalDurationMinutes > 0 {
            parts.append(LocalizedPlanText.completedDurationLine(summary.totalDurationMinutes, locale: locale))
        }
        if summary.totalDistanceKm > 0 {
            parts.append(LocalizedPlanText.completedDistanceLine(summary.totalDistanceKm.cleanDistance, locale: locale))
        }
        return parts.joined(separator: " · ")
    }

    private func summaryChip(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.textMuted)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
        .cornerRadius(AppRadius.lg)
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
                    .font(.exerciseName)
                    .foregroundColor(.textPrimary)

                Spacer()

                Text(LocalizedPlanText.completedStrengthBadge(exercise.completedSetCount, locale: locale))
                    .font(.system(size: 12, weight: .semibold))
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
                .font(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            infoChip(loadText, accentColor: loadTint)

            Text("×")
                .font(.setIndex)
                .foregroundColor(Color.accentBorder.opacity(0.55))

            infoChip(
                LocalizedPlanText.formatted("history.completed.reps_value", locale: locale, Int64(set.reps)),
                accentColor: .accentPrimary
            )

            Spacer(minLength: 4)

            if let rpe = set.rpe {
                Text("RPE \(rpe.cleanRPE)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.textMuted)
            }

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 21, weight: .semibold))
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
        case .unrecordedWeight:
            return String(localized: "history.completed.unrecorded_weight")
        }
    }

    private var loadTint: Color {
        switch set.loadDisplay {
        case .weighted:
            return .accentPrimary
        case .bodyweight:
            return .green
        case .unrecordedWeight:
            return .orange
        }
    }

    private func infoChip(_ text: String, accentColor: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
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
                    .font(.exerciseName)
                    .foregroundColor(.textPrimary)

                Spacer()

                Text(sourceLabel)
                    .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 12))
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
        case .chat:
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.textMuted)
            Text(value)
                .font(.system(size: 15, weight: .bold))
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
