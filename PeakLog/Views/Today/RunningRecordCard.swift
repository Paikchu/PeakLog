import SwiftUI

struct RunningRecordCard: View {
    let record: RunningWorkoutRecord
    var isPreview: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: record.activityType.iconName)
                    .foregroundColor(.accentPrimary)
                Text(isPreview ? "\(record.activityType.title)预览" : record.activityType.title)
                    .appFont(size: 15, weight: .semibold)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(sourceLabel)
                    .appFont(size: 12, weight: .medium)
                    .foregroundColor(.textMuted)
            }

            HStack(spacing: 12) {
                metric(title: "时长", value: "\(record.durationMinutes) 分钟")
                if let distanceKm = record.distanceKm {
                    metric(title: "里程", value: "\(distanceKm.cleanDistance) km")
                }
                if let rpe = record.rpe {
                    metric(title: "RPE", value: rpe.cleanDistance)
                }
            }

            Text(dateLabel)
                .appFont(size: 12)
                .foregroundColor(.textMuted)
        }
        .padding(14)
        .background(Color.appSurface)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.appSeparator, lineWidth: 0.5)
        )
    }

    private var sourceLabel: String {
        switch record.source {
        case .agent:
            return "AI"
        case .manual:
            return "手动"
        }
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: record.createdAt)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(size: 12, weight: .medium)
                .foregroundColor(.textMuted)
            Text(value)
                .appFont(size: 18, weight: .bold)
                .foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.workoutPanel.opacity(0.6))
        .cornerRadius(12)
    }
}

private extension Double {
    var cleanDistance: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }
}
