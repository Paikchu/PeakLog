import CoreGraphics
import Foundation

struct ExerciseCardSwipeGestureCoordinator {
    enum AxisLock: Equatable {
        case horizontal
        case vertical
    }

    struct Decision: Equatable {
        let lockAxis: AxisLock?
        let nextOffset: CGFloat
    }

    func shouldBeginPan(velocity: CGPoint, translation: CGSize) -> Bool {
        if let axis = resolveAxisLock(horizontal: abs(velocity.x), vertical: abs(velocity.y)) {
            return axis == .horizontal
        }

        if let axis = resolveAxisLock(horizontal: abs(translation.width), vertical: abs(translation.height)) {
            return axis == .horizontal
        }

        return false
    }

    func decision(
        translation: CGSize,
        currentOffset: CGFloat,
        deleteWidth: CGFloat,
        lockedAxis: AxisLock? = nil
    ) -> Decision {
        let axis = lockedAxis ?? resolveAxisLock(for: translation)

        guard axis == .horizontal else {
            return Decision(lockAxis: axis, nextOffset: currentOffset)
        }

        let delta = translation.width
        let nextOffset: CGFloat
        if delta < 0 {
            nextOffset = max(-deleteWidth, delta)
        } else {
            nextOffset = min(0, (currentOffset < 0 ? -deleteWidth : 0) + delta)
        }

        return Decision(lockAxis: .horizontal, nextOffset: nextOffset)
    }

    func finalOffset(
        translation: CGSize,
        currentOffset: CGFloat,
        deleteWidth: CGFloat,
        lockedAxis: AxisLock?
    ) -> CGFloat {
        let decision = decision(
            translation: translation,
            currentOffset: currentOffset,
            deleteWidth: deleteWidth,
            lockedAxis: lockedAxis
        )

        guard decision.lockAxis == .horizontal else {
            return currentOffset
        }

        return translation.width < -deleteWidth / 2 ? -deleteWidth : 0
    }

    private func resolveAxisLock(for translation: CGSize) -> AxisLock? {
        resolveAxisLock(horizontal: abs(translation.width), vertical: abs(translation.height))
    }

    private func resolveAxisLock(horizontal: CGFloat, vertical: CGFloat) -> AxisLock? {
        guard max(horizontal, vertical) > 0 else {
            return nil
        }

        if horizontal > vertical {
            return .horizontal
        }

        if vertical > horizontal {
            return .vertical
        }

        return nil
    }
}
