import SwiftUI

struct PRSummaryCard: View {
    let summary: PRSummaryBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: summary.items.isEmpty ? "flag.slash" : "trophy.fill")
                    .foregroundColor(summary.items.isEmpty ? .textMuted : Color.accentValue)
                Text(summary.summaryText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textPrimary)
            }

            if !summary.items.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(summary.items.enumerated()), id: \.offset) { _, item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Text(detailText(for: item))
                                    .font(.system(size: 12))
                                    .foregroundColor(.textSecondary)
                            }
                            Spacer()
                            Text("\(formatWeight(item.currentWeight))\(item.weightUnit)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Color.accentValue)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(summary.items.isEmpty ? Color.appSeparator : Color.accentValue.opacity(0.3), lineWidth: 1)
        )
    }

    private func detailText(for item: PRSummaryItem) -> String {
        if let previous = item.previousWeight {
            return "\(formatWeight(previous))\(item.weightUnit) → \(formatWeight(item.currentWeight))\(item.weightUnit)"
        }
        return String(localized: "First recorded PR")
    }

    private func formatWeight(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

#Preview {
    PRSummaryCard(summary: PRSummaryBlock(
        summaryText: "New PR: Bench Press 85kg.",
        items: [
            PRSummaryItem(
                normalizedName: "bench press",
                displayName: "Bench Press",
                previousWeight: 80,
                currentWeight: 85,
                weightUnit: "kg",
                isNewRecord: true
            )
        ]
    ))
    .padding()
    .background(Color.appBackground)
}
