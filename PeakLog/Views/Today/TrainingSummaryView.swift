import SwiftUI

/// 「结束并保存」后的训练小结弹层：时长 / 总容量 / 完成组数、
/// 新纪录提示与逐动作明细。数据在 confirm 时一次性算好
/// （`TrainingSessionSummary`），本视图纯展示。
struct TrainingSummaryView: View {
    let summary: TrainingSessionSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    statTiles
                    if summary.newRecordCount > 0 {
                        newRecordsPanel
                    }
                    exerciseBreakdown
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }

            doneButton
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .accessibilityIdentifier("training_summary.sheet")
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .appFont(size: 46, weight: .semibold)
                .foregroundStyle(Color.green)

            Text("training_session.summary.title")
                .appFont(size: 22, weight: .bold)
                .foregroundColor(.textPrimary)

            Text(summary.title)
                .appFont(size: 14, weight: .medium)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stats

    private var statTiles: some View {
        HStack(spacing: 10) {
            if let duration = summary.durationDisplay {
                statTile(
                    value: duration,
                    label: String(localized: "training_session.summary.duration")
                )
            }
            statTile(
                value: summary.volumeDisplay,
                label: String(localized: "training_session.summary.volume")
            )
            statTile(
                value: "\(summary.completedSets)/\(summary.totalSets)",
                label: String(localized: "training_session.summary.sets")
            )
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .appFont(size: 20, weight: .bold, design: .rounded)
                .foregroundColor(.accentValue)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .appFont(size: 11, weight: .medium)
                .foregroundColor(.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Color.appSurface)
        )
    }

    // MARK: - New records

    private var newRecordsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .appFont(size: 15, weight: .semibold)
                    .foregroundColor(.orange)

                Text(LocalizedPlanText.formatted(
                    "training_session.summary.pr_count",
                    locale: locale,
                    Int64(summary.newRecordCount)
                ))
                .appFont(size: 15, weight: .bold)
                .foregroundColor(.textPrimary)
            }

            ForEach(summary.newRecordExercises) { exercise in
                HStack(spacing: 8) {
                    Text(exercise.name)
                        .appFont(size: 13, weight: .semibold)
                        .foregroundColor(.textSecondary)
                    Spacer()
                    if let best = exercise.bestSetDisplay {
                        Text(best)
                            .appFont(size: 13, weight: .bold, design: .rounded)
                            .foregroundColor(.accentValue)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("training_summary.newRecords")
    }

    // MARK: - Breakdown

    private var exerciseBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("training_session.summary.exercises")
                .appFont(size: 13, weight: .bold)
                .foregroundColor(.textMuted)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(summary.exercises) { exercise in
                    breakdownRow(exercise)

                    if exercise.id != summary.exercises.last?.id {
                        Rectangle()
                            .fill(Color.appSeparator)
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .fill(Color.appSurface)
            )
        }
    }

    private func breakdownRow(_ exercise: TrainingSessionSummary.ExerciseSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: exercise.completedSets >= exercise.totalSets ? "checkmark.circle.fill" : "circle.dotted")
                .appFont(size: 15, weight: .semibold)
                .foregroundColor(exercise.completedSets >= exercise.totalSets ? .green : .textMuted)

            Text(exercise.name)
                .appFont(size: 14, weight: .semibold)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if exercise.isNewRecord {
                Text(verbatim: "PR")
                    .appFont(size: 10, weight: .bold, design: .rounded)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }

            if exercise.wasSkipped {
                Text("training_session.skipped")
                    .appFont(size: 10, weight: .bold)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let best = exercise.bestSetDisplay {
                    Text(best)
                        .appFont(size: 13, weight: .bold, design: .rounded)
                        .foregroundColor(.accentValue)
                }
                Text("\(exercise.completedSets)/\(exercise.totalSets)")
                    .appFont(size: 11, weight: .medium, design: .rounded)
                    .foregroundColor(.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Done

    private var doneButton: some View {
        Button {
            dismiss()
        } label: {
            Text("training_session.summary.done")
                .appFont(size: 16, weight: .bold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassActionBackground(cornerRadius: AppRadius.full, tint: Color.accentPrimary.opacity(0.85))
        .clipShape(Capsule())
        .accessibilityIdentifier("training_summary.done")
    }
}

#Preview {
    TrainingSummaryView(summary: TrainingSessionSummary(
        id: "preview",
        title: "推力日 · 胸肩",
        durationSeconds: 2530,
        completedSets: 11,
        totalSets: 12,
        totalVolumeKg: 3240,
        preferredUnit: .kg,
        exercises: [
            .init(
                id: "e1", name: "杠铃卧推", completedSets: 4, totalSets: 4,
                bestSetDisplay: "62.5 kg × 8", bestWeightKg: 62.5, isNewRecord: true, wasSkipped: false
            ),
            .init(
                id: "e2", name: "上斜哑铃推举", completedSets: 4, totalSets: 4,
                bestSetDisplay: "24 kg × 10", bestWeightKg: 24, isNewRecord: false, wasSkipped: false
            ),
            .init(
                id: "e3", name: "绳索飞鸟", completedSets: 3, totalSets: 4,
                bestSetDisplay: "15 kg × 12", bestWeightKg: 15, isNewRecord: false, wasSkipped: true
            )
        ]
    ))
}
