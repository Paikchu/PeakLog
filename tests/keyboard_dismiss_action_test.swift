import Foundation

@main
struct KeyboardDismissActionTestRunner {
    static func main() {
        dismissActionInvokesInjectedHandler()
        print("keyboard_dismiss_action_test passed")
    }

    private static func dismissActionInvokesInjectedHandler() {
        var callCount = 0
        let action = KeyboardDismissAction {
            callCount += 1
        }

        action()

        precondition(callCount == 1, "Expected dismiss handler to run exactly once")
    }
}
