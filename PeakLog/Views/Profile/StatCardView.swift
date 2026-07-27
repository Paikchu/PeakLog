import SwiftUI

struct StatCardView: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .appFont(size: 16, weight: .semibold)
                    .foregroundColor(iconColor)
            }

            Text(value)
                .appFont(.statValue)
                .foregroundColor(.textPrimary)

            Text(label)
                .appFont(.statLabel)
                .foregroundColor(.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

#Preview {
    HStack(spacing: 8) {
        StatCardView(icon: "trophy.fill", iconColor: .accentPrimary, value: "47", label: "Workouts")
        StatCardView(icon: "flame.fill", iconColor: .orange, value: "12d", label: "Streak")
        StatCardView(icon: "chart.line.uptrend.xyaxis", iconColor: .green, value: "24t", label: "Volume")
        StatCardView(icon: "star.fill", iconColor: .yellow, value: "8", label: "PRs")
    }
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
