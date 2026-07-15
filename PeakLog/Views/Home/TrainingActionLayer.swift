import SwiftUI

/// Dock 上方的训练动作层，两种状态共用同一个位置：
/// - `.start`：计划页专属的「开始训练」CTA（今日有计划且无活跃 session）。
/// - `.resume`：有最小化的活跃 session 时全局显示的「训练进行中」卡片。
struct TrainingActionLayer: View {
    enum State: Equatable {
        case start
        case resume(completed: Int, total: Int)
    }

    let state: State
    let action: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            switch state {
            case .start:
                startButton
            case .resume(let completed, let total):
                resumeCard(completed: completed, total: total)
            }
        }
        .padding(.horizontal, HomeDockMetrics.outerHorizontalPadding)
    }

    private var startButton: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("today.start_training")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassActionBackground(cornerRadius: AppRadius.full, tint: Color.accentPrimary.opacity(0.85))
        .clipShape(Capsule())
        .accessibilityIdentifier("today.startPlan")
    }

    private func resumeCard(completed: Int, total: Int) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("training_session.in_progress")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text(LocalizedPlanText.setsCompleted(
                        completed: completed,
                        total: total,
                        locale: locale
                    ))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textSecondary)
                    .contentTransition(.numericText())
                }

                Spacer()

                Text("training_session.resume")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassActionBackground(cornerRadius: AppRadius.full, tint: Color.accentPrimary.opacity(0.45))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassPanel(cornerRadius: AppRadius.full)
        .accessibilityIdentifier("training_focus.resumeBanner")
    }
}

#Preview {
    ZStack {
        Color.appBackground.ignoresSafeArea()
        VStack(spacing: 16) {
            Spacer()
            TrainingActionLayer(state: .start, action: {})
            TrainingActionLayer(state: .resume(completed: 3, total: 15), action: {})
        }
    }
}
