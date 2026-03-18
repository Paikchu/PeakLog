import SwiftUI

struct HistoryScreen: View {
    @StateObject private var viewModel = HistoryViewModel()
    var onBack: (() -> Void)?

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
            await viewModel.loadCalendar()
            await viewModel.loadSessionsForSelectedDate()
        }
    }

    // MARK: - Header
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

            Text("Workout History")
                .font(.screenTitle)
                .foregroundColor(.textPrimary)

            Spacer()

            // Spacer to balance the back button
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Session List
    @ViewBuilder
    private var sessionList: some View {
        if viewModel.isLoadingSessions {
            ProgressView()
                .padding(.top, 20)
        } else if viewModel.sessions.isEmpty {
            Text("No workouts on this day")
                .font(.chatBody)
                .foregroundColor(.textMuted)
                .padding(.top, 20)
        } else {
            VStack(spacing: 12) {
                ForEach(viewModel.sessions) { session in
                    SessionDetailRow(session: session)
                        .padding(.horizontal, 16)
                }
            }
        }
    }
}

#Preview {
    HistoryScreen()
        .preferredColorScheme(.dark)
}
