import SwiftUI

struct ChatScrollKeyboardDismissBehavior {
    let dismissesOnScroll: Bool

    #if canImport(UIKit)
    let mode: ScrollDismissesKeyboardMode

    init(mode: ScrollDismissesKeyboardMode = .immediately) {
        self.dismissesOnScroll = mode != .never
        self.mode = mode
    }
    #else
    init(dismissesOnScroll: Bool = true) {
        self.dismissesOnScroll = dismissesOnScroll
    }
    #endif
}

private struct ChatScrollKeyboardDismissModifier: ViewModifier {
    let behavior: ChatScrollKeyboardDismissBehavior

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.scrollDismissesKeyboard(behavior.mode)
        #else
        content
        #endif
    }
}

extension View {
    func chatScrollDismissesKeyboard(
        _ behavior: ChatScrollKeyboardDismissBehavior = ChatScrollKeyboardDismissBehavior()
    ) -> some View {
        modifier(ChatScrollKeyboardDismissModifier(behavior: behavior))
    }
}
