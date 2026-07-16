import SwiftUI

/// 过去日期的内容区：只陈述事实——完成统计 pill + 已完成训练明细，
/// 没有记录时给空状态。不显示"计划了但没练"的信息，也没有任何编辑入口。
struct PastDayContent: View {
    @ObservedObject var viewModel: HistoryViewModel
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.isLoadingSessions {
                    ProgressView()
                        .padding(.top, 40)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .appFont(.chatBody)
                        .foregroundColor(.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 20)
                } else if !viewModel.hasCompletedRecords {
                    emptyState
                } else {
                    completedSummaryRow
                    HistoryCompletedTrainingSection(
                        summary: viewModel.completedDaySummary,
                        strengthExercises: viewModel.completedStrengthExercises,
                        cardioRecords: viewModel.completedCardioRecords
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 104)
        }
    }

    private var emptyState: some View {
        let content = HistoryEmptyStateContent.resolve(
            selectedDate: viewModel.selectedDate,
            today: Date(),
            locale: locale
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text(content.title)
                .appFont(.rootPageTitle)
                .foregroundColor(.textPrimary)
            Text(content.subtitle)
                .appFont(size: 15)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 28)
    }

    // MARK: - Completed Day Summary Pills

    private var completedSummaryRow: some View {
        let summary = viewModel.completedDaySummary
        return HStack(spacing: 8) {
            if summary.strengthExerciseCount > 0 {
                summaryPill(
                    value: LocalizedPlanText.completedStrengthValue(summary.strengthExerciseCount, locale: locale),
                    tint: .accentPrimary
                )
            }
            if summary.strengthSetCount > 0 {
                summaryPill(
                    value: LocalizedPlanText.completedSetValue(summary.strengthSetCount, locale: locale),
                    tint: .green
                )
            }
            if summary.cardioRecordCount > 0 {
                summaryPill(
                    value: LocalizedPlanText.completedCardioValue(summary.cardioRecordCount, locale: locale),
                    tint: .teal
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func summaryPill(value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(value)
                .appFont(size: 12, weight: .semibold)
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
        .clipShape(Capsule())
    }
}

#Preview {
    PastDayContent(viewModel: HistoryViewModel())
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
}
