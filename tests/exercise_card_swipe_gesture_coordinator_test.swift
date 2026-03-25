import CoreGraphics
import Foundation

@main
struct ExerciseCardSwipeGestureCoordinatorTestRunner {
    static func main() {
        allowsPanForHorizontalVelocity()
        rejectsPanForVerticalVelocity()
        fallsBackToTranslationWhenVelocityIsFlat()
        doesNotLockForVerticalDrag()
        locksForHorizontalDrag()
        keepsExistingHorizontalLock()
        keepsExistingOpenOffsetWithinBounds()
        print("exercise_card_swipe_gesture_coordinator_test passed")
    }

    private static func allowsPanForHorizontalVelocity() {
        let coordinator = ExerciseCardSwipeGestureCoordinator()
        let shouldBegin = coordinator.shouldBeginPan(
            velocity: CGPoint(x: -640, y: 120),
            translation: CGSize.zero
        )

        precondition(
            shouldBegin,
            "Expected strong horizontal velocity to start swipe handling"
        )
    }

    private static func rejectsPanForVerticalVelocity() {
        let coordinator = ExerciseCardSwipeGestureCoordinator()
        let shouldBegin = coordinator.shouldBeginPan(
            velocity: CGPoint(x: 80, y: 540),
            translation: CGSize.zero
        )

        precondition(
            !shouldBegin,
            "Expected strong vertical velocity to stay with parent scroll handling"
        )
    }

    private static func fallsBackToTranslationWhenVelocityIsFlat() {
        let coordinator = ExerciseCardSwipeGestureCoordinator()
        let shouldBegin = coordinator.shouldBeginPan(
            velocity: CGPoint.zero,
            translation: CGSize(width: -24, height: 4)
        )

        precondition(
            shouldBegin,
            "Expected horizontal displacement to enable swipe when velocity is not yet informative"
        )
    }

    private static func doesNotLockForVerticalDrag() {
        let coordinator = ExerciseCardSwipeGestureCoordinator()
        let decision = coordinator.decision(
            translation: CGSize(width: 6, height: 24),
            currentOffset: 0,
            deleteWidth: 72
        )

        precondition(
            decision.lockAxis == .vertical,
            "Expected predominantly vertical drag to stay classified as vertical"
        )
        precondition(
            decision.nextOffset == 0,
            "Expected predominantly vertical drag not to move the card"
        )
    }

    private static func locksForHorizontalDrag() {
        let coordinator = ExerciseCardSwipeGestureCoordinator()
        let decision = coordinator.decision(
            translation: CGSize(width: -44, height: 8),
            currentOffset: 0,
            deleteWidth: 72
        )

        precondition(
            decision.lockAxis == .horizontal,
            "Expected predominantly horizontal drag to lock horizontal swipe handling"
        )
        precondition(
            decision.nextOffset == -44,
            "Expected horizontal drag to update the card offset"
        )
    }

    private static func keepsExistingHorizontalLock() {
        let coordinator = ExerciseCardSwipeGestureCoordinator()
        let decision = coordinator.decision(
            translation: CGSize(width: -12, height: 40),
            currentOffset: -24,
            deleteWidth: 72,
            lockedAxis: .horizontal
        )

        precondition(
            decision.lockAxis == .horizontal,
            "Expected an already horizontal interaction to remain locked horizontally"
        )
        precondition(
            decision.nextOffset == -12,
            "Expected locked horizontal interaction to keep driving offset updates"
        )
    }

    private static func keepsExistingOpenOffsetWithinBounds() {
        let coordinator = ExerciseCardSwipeGestureCoordinator()
        let decision = coordinator.decision(
            translation: CGSize(width: -120, height: 6),
            currentOffset: 0,
            deleteWidth: 72
        )

        precondition(
            decision.nextOffset == -72,
            "Expected swipe offset to stay clamped to the delete affordance width"
        )
    }
}
