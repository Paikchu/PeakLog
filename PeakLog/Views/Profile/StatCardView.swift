import SwiftUI

struct StatCardView: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            Text(value)
                .font(.statValue)
                .foregroundColor(.textPrimary)

            Text(label)
                .font(.statLabel)
                .foregroundColor(.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(
                    colorScheme == .light ? Color(hex: "#f3f4f6") : Color.clear,
                    lineWidth: 0.75
                )
        )
        .shadow(
            color: colorScheme == .light ? Color.black.opacity(0.07) : .clear,
            radius: 3, x: 0, y: 1
        )
    }
}

#Preview {
    HStack(spacing: 8) {
        StatCardView(icon: "trophy.fill", iconColor: .accentPurple, value: "47", label: "Workouts")
        StatCardView(icon: "flame.fill", iconColor: .orange, value: "12d", label: "Streak")
        StatCardView(icon: "chart.line.uptrend.xyaxis", iconColor: .green, value: "24t", label: "Volume")
        StatCardView(icon: "star.fill", iconColor: .yellow, value: "8", label: "PRs")
    }
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
