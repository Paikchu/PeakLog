import SwiftUI

/// 挂在 `safeAreaInset(edge: .bottom)` 上的底部操作栏共用度量。
///
/// `safeAreaInset` 会把底部安全区让给 inset 内容，但**不会**再多留一丝空隙：
/// 不写 `bottomPadding` 时按钮下沿正好压在安全区边界上（实测 iPhone 17 Pro Max
/// 上距屏幕底 34pt），紧贴 Home Indicator 的手势区，看着挤、点着也容易被系统
/// 的上滑识别器抢走。所有底部 CTA 统一用这里的值留出呼吸位。
enum BottomActionBarMetrics {
    static let horizontalPadding: CGFloat = 22
    static let bottomPadding: CGFloat = 12
}

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
        .padding(.horizontal, BottomActionBarMetrics.horizontalPadding)
        .padding(.bottom, BottomActionBarMetrics.bottomPadding)
    }

    private var startButton: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .appFont(size: 14, weight: .bold)
                Text("today.start_training")
                    .appFont(size: 16, weight: .bold)
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
                    .appFont(size: 17, weight: .semibold)
                    .foregroundColor(.accentPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("training_session.in_progress")
                        .appFont(size: 14, weight: .bold)
                        .foregroundColor(.textPrimary)
                    Text(LocalizedPlanText.setsCompleted(
                        completed: completed,
                        total: total,
                        locale: locale
                    ))
                    .appFont(size: 12, weight: .medium)
                    .foregroundColor(.textSecondary)
                    .contentTransition(.numericText())
                }

                Spacer()

                Text("training_session.resume")
                    .appFont(size: 13, weight: .bold)
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
