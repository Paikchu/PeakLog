import SwiftUI

struct HistoryScreen: View {
    @StateObject private var viewModel = HistoryViewModel()
    var onBack: (() -> Void)?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    planSection

                    CalendarGridView(viewModel: viewModel)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    sessionList
                }
                .padding(.bottom, 24)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .task {
            await viewModel.loadPlan()
            await viewModel.loadCalendar()
            await viewModel.loadSessionsForSelectedDate()
        }
    }

    private var header: some View {
        HStack {
            Button {
                onBack?()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .frame(width: 38, height: 38)
            }

            Spacer()

            Text("history.title")
                .font(.screenTitle)
                .foregroundColor(.textPrimary)

            Spacer()

            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var planSection: some View {
        if let plan = viewModel.activePlan {
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Plan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textMuted)
                Text(LocalizedPlanText.weekOf(plan.weekStartDate, locale: locale))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPrimary)
                if let goalSummary = plan.goalSummary, !goalSummary.isEmpty {
                    Text(goalSummary)
                        .font(.system(size: 13))
                        .foregroundColor(.textSecondary)
                }
                Text(
                    LocalizedPlanText.weeklyPlanSummary(
                        trainingDays: plan.days.filter { $0.status != "rest" }.count,
                        completedSets: plan.completedSetsCount,
                        totalSets: plan.totalSetsCount,
                        locale: locale
                    )
                )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.appSurface)
            .cornerRadius(18)
            .padding(.horizontal, 16)
        } else if !viewModel.isLoadingPlan {
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Plan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textMuted)
                Text("No active plan yet")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("Ask the AI coach in chat to create your weekly plan.")
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.appSurface)
            .cornerRadius(18)
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if viewModel.isLoadingSessions {
            ProgressView()
                .padding(.top, 20)
        } else if !viewModel.hasCompletedRecords {
            Text("history.empty")
                .font(.chatBody)
                .foregroundColor(.textMuted)
                .padding(.top, 20)
        } else {
            HistoryCompletedTrainingSection(
                summary: viewModel.completedDaySummary,
                strengthExercises: viewModel.completedStrengthExercises,
                cardioRecords: viewModel.completedCardioRecords
            )
            .padding(.horizontal, 16)
        }
    }
}

#Preview {
    HistoryScreen()
        .preferredColorScheme(.dark)
}
