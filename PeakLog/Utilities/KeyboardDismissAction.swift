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

    private static func defaultDismissHandler() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
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
