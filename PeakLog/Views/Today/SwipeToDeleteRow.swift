import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 由右向左滑动露出删除按钮的容器（iOS 原生风格）：滑动只负责展开/收起按钮，
/// 只有点击删除按钮才会真正删除，避免误删。
/// 卡片区域不在 List 内，无法使用系统 swipeActions，这里用横向拖拽手势实现，
/// 纵向拖动仍交给外层 ScrollView。
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    @State private var offsetX: CGFloat = 0
    @State private var isRevealed = false

    private let actionWidth: CGFloat = 76
    // 超过按钮宽度后的橡皮筋余量。
    private let overshoot: CGFloat = 28

    var body: some View {
        content
            .offset(x: offsetX)
            .overlay {
                if isRevealed {
                    // 按钮展开期间点击卡片先收起，避免误触卡片内部的编辑按钮。
                    Color.clear
                        .contentShape(Rectangle())
                        .offset(x: offsetX)
                        .onTapGesture { setRevealed(false) }
                }
            }
            .background(alignment: .trailing) { deleteAction }
            .gesture(dragGesture)
            .accessibilityAction(named: Text("common.delete")) { onDelete() }
    }

    private var deleteAction: some View {
        Button(action: triggerDelete) {
            VStack(spacing: 4) {
                Image(systemName: "trash.fill")
                    .appFont(size: 17, weight: .semibold)
                Text("common.delete")
                    .appFont(size: 11, weight: .semibold)
            }
            .foregroundColor(.white)
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .fill(Color.red)
            )
        }
        .buttonStyle(.plain)
        .opacity(offsetX < -8 ? 1 : 0)
        .accessibilityIdentifier("swipe_row.delete")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                // 只跟随横向手势，纵向滚动交给 ScrollView。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offsetX = clampedOffset(for: baseOffset + value.translation.width)
            }
            .onEnded { value in
                // 松手只决定按钮展开或收起，删除必须点按钮。
                let proposed = baseOffset + value.translation.width
                setRevealed(proposed <= -actionWidth / 2)
            }
    }

    /// 向左超过按钮宽度后按 1/4 比例橡皮筋衰减，向右不允许拖出。
    private func clampedOffset(for proposed: CGFloat) -> CGFloat {
        if proposed >= 0 { return 0 }
        if proposed >= -actionWidth { return proposed }
        let excess = -proposed - actionWidth
        return -actionWidth - min(excess / 4, overshoot)
    }

    private var baseOffset: CGFloat {
        isRevealed ? -actionWidth : 0
    }

    private func setRevealed(_ revealed: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            isRevealed = revealed
            offsetX = revealed ? -actionWidth : 0
        }
    }

    private func triggerDelete() {
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
        // 删除失败（行保留）时回到收起状态。
        setRevealed(false)
        onDelete()
    }
}

#Preview {
    VStack(spacing: 16) {
        SwipeToDeleteRow(onDelete: {}) {
            Text("Swipe me")
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(Color.appSurface)
                .cornerRadius(AppRadius.xl)
        }
    }
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
