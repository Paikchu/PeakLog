import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct KeyboardDismissAction {
    private let dismissHandler: () -> Void

    init(dismissHandler: @escaping () -> Void = Self.defaultDismissHandler) {
        self.dismissHandler = dismissHandler
    }

    func callAsFunction() {
        dismissHandler()
    }

    private nonisolated static func defaultDismissHandler() {
        #if canImport(UIKit)
        // `UIApplication` 是 Main Actor 隔离的。把访问包进 `MainActor.assumeIsolated`
        // 里，既保证在正确的执行上下文里收起键盘，又让本函数保持非隔离，
        // 从而消除 `init` 默认参数（非隔离上下文）调用它产生的隔离冲突。
        _ = MainActor.assumeIsolated {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        #endif
    }
}

private struct DismissKeyboardOnTapModifier: ViewModifier {
    let dismissKeyboard: KeyboardDismissAction

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissKeyboard()
                }
            )
    }
}

extension View {
    func dismissKeyboardOnTap(
        dismissKeyboard: KeyboardDismissAction = KeyboardDismissAction()
    ) -> some View {
        modifier(DismissKeyboardOnTapModifier(dismissKeyboard: dismissKeyboard))
    }
}
