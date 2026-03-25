import SwiftUI

#if canImport(UIKit)
import UIKit

struct ExerciseCardPanGesture: UIViewRepresentable {
    let swipeCoordinator: ExerciseCardSwipeGestureCoordinator
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(swipeCoordinator: swipeCoordinator)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.swipeCoordinator = swipeCoordinator
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        uiView.onDidMoveToSuperview = { superview in
            context.coordinator.attach(to: superview)
        }

        DispatchQueue.main.async {
            context.coordinator.attach(to: uiView.superview)
        }
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        var onDidMoveToSuperview: ((UIView?) -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onDidMoveToSuperview?(superview)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var swipeCoordinator: ExerciseCardSwipeGestureCoordinator
        var onChanged: ((CGSize) -> Void)?
        var onEnded: ((CGSize) -> Void)?
        private weak var attachedView: UIView?
        private lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            return recognizer
        }()

        init(swipeCoordinator: ExerciseCardSwipeGestureCoordinator) {
            self.swipeCoordinator = swipeCoordinator
        }

        func attach(to view: UIView?) {
            guard let view else { return }
            guard attachedView !== view else { return }

            detach()
            view.addGestureRecognizer(recognizer)
            attachedView = view
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            attachedView = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }

            let velocity = panRecognizer.velocity(in: gestureRecognizer.view)
            let translation = panRecognizer.translation(in: gestureRecognizer.view)
            return swipeCoordinator.shouldBeginPan(
                velocity: velocity,
                translation: CGSize(width: translation.x, height: translation.y)
            )
        }

        @objc
        private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            let size = CGSize(width: translation.x, height: translation.y)

            switch recognizer.state {
            case .changed:
                onChanged?(size)
            case .ended, .cancelled, .failed:
                onEnded?(size)
            default:
                break
            }
        }
    }
}
#endif
