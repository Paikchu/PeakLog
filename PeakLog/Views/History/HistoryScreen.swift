import SwiftUI

struct HistoryScreen: View {
    @StateObject private var viewModel = HistoryViewModel()
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
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
        Text("history.title")
            .font(.screenTitle)
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
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
