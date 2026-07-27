import SwiftUI

enum ProfileLayout {
    static let horizontalPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 32
    static let cardRadius: CGFloat = 18
}

struct ProfilePerformanceDashboard: View {
    let volume: String
    let workouts: String
    let streak: String
    let personalRecords: String

    private var volumeParts: (value: String, unit: String) {
        for unit in ["k lbs", "lbs", "kg", "t"] where volume.hasSuffix(unit) {
            let value = volume.dropLast(unit.count).trimmingCharacters(in: .whitespaces)
            return (String(value), unit)
        }
        return (volume, "")
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("profile.stats.volume")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundColor(.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(volumeParts.value)
                        .appFont(size: 32, weight: .bold, design: .rounded, relativeTo: .title)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if !volumeParts.unit.isEmpty {
                        Text(volumeParts.unit)
                            .appFont(size: 16, weight: .bold, design: .rounded, relativeTo: .body)
                            .foregroundColor(.accentValue)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Divider()
                .background(Color.appSeparator)

            VStack(spacing: 8) {
                ProfileMetricRow(label: "profile.stats.workouts", value: workouts)
                Divider()
                    .background(Color.appSeparator)
                ProfileMetricRow(label: "profile.stats.streak", value: streak)
                Divider()
                    .background(Color.appSeparator)
                ProfileMetricRow(
                    label: "profile.stats.prs",
                    value: personalRecords,
                    valueColor: .accentValue
                )
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(minHeight: 144)
        .background(Color.appSurface)
        .cornerRadius(ProfileLayout.cardRadius)
    }
}

private struct ProfileMetricRow: View {
    let label: LocalizedStringKey
    let value: String
    var valueColor: Color = .textPrimary

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .appFont(size: 12, weight: .medium)
                .foregroundColor(.textMuted)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .appFont(size: 16, weight: .bold, design: .rounded, relativeTo: .callout)
                .foregroundColor(valueColor)
                .lineLimit(1)
        }
    }
}

#Preview {
    ProfilePerformanceDashboard(
        volume: "400kg",
        workouts: "1",
        streak: "0d",
        personalRecords: "1"
    )
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
