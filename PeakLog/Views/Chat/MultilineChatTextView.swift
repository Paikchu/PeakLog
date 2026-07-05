import SwiftUI

#if canImport(UIKit)
import UIKit

struct MultilineChatTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var calculatedHeight: CGFloat
    @Binding var isFocused: Bool

    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 14.5, weight: .regular)
        textView.textColor = UIColor(Color.textPrimary)
        textView.tintColor = UIColor(Color.accentPrimary)
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.textContainerInset = UIEdgeInsets(
            top: chatInputBarTextVerticalInset,
            left: 0,
            bottom: chatInputBarTextVerticalInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.returnKeyType = .default
        textView.keyboardDismissMode = .interactive
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityLabel = placeholder
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }

        recalculateHeight(for: uiView)
    }

    private func recalculateHeight(for textView: UITextView) {
        let fallbackWidth = textView.window?.windowScene?.screen.bounds.width ?? 320
        let targetWidth = textView.bounds.width > 0 ? textView.bounds.width : fallbackWidth
        let fittingSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        let measuredHeight = textView.sizeThatFits(fittingSize).height
        let lineHeight = textView.font?.lineHeight ?? 0
        let minHeight = minimumTextViewHeight(lineHeight: lineHeight, textView: textView)
        let maxHeight = maximumTextViewHeight(lineHeight: lineHeight, textView: textView)
        let clampedHeight = min(max(measuredHeight, minHeight), maxHeight)
        let shouldScroll = measuredHeight > maxHeight + 0.5

        if textView.isScrollEnabled != shouldScroll {
            textView.isScrollEnabled = shouldScroll
            textView.showsVerticalScrollIndicator = shouldScroll
        }

        if abs(calculatedHeight - clampedHeight) > 0.5 {
            DispatchQueue.main.async {
                calculatedHeight = clampedHeight
            }
        }
    }

    private func minimumTextViewHeight(lineHeight: CGFloat, textView: UITextView) -> CGFloat {
        lineHeight * CGFloat(chatInputBarMinimumVisibleLineCount)
            + textView.textContainerInset.top
            + textView.textContainerInset.bottom
    }

    private func maximumTextViewHeight(lineHeight: CGFloat, textView: UITextView) -> CGFloat {
        lineHeight * CGFloat(chatInputBarMaximumVisibleLineCount)
            + textView.textContainerInset.top
            + textView.textContainerInset.bottom
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var parent: MultilineChatTextView

        init(parent: MultilineChatTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.recalculateHeight(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}
#endif
