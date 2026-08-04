import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

let authView = try source("PeakLog/Views/Auth/AuthView.swift")
let authProtocol = try source("PeakLog/Services/Auth/AuthProviding.swift")
let cloudE2E = try source("PeakLog/Services/Cloud/CloudSyncE2ECheck.swift")
let entitlements = try source("PeakLog/PeakLog.entitlements")
let localizable = try source("PeakLog/Localizable.xcstrings")

precondition(
    authView.contains("import AuthenticationServices")
        && authView.contains("SignInWithAppleButton(.signIn)")
        && authView.contains("request.requestedScopes = [.fullName, .email]")
        && authView.contains("request.nonce = nonce.hashedValue")
        && authView.contains(".id(colorScheme)")
        && authView.contains(".accessibilityIdentifier(\"apple-sign-in-button\")"),
    "Release login must use the native Apple button and redraw it when appearance changes"
)
precondition(
    authView.contains("TextField(\"auth.email.placeholder\"")
        && authView.contains("SecureField(\"auth.password.placeholder\"")
        && authView.contains("auth.signIn(email: email, password: password)")
        && authView.contains(".accessibilityIdentifier(\"email-field\")")
        && authView.contains(".accessibilityIdentifier(\"password-field\")")
        && authView.contains(".accessibilityIdentifier(\"email-sign-in-button\")"),
    "Release login must expose the email/password sign-in form, addressable by automation"
)
// Password AutoFill only pairs a username field with a password field when the
// former is `.username`. `.emailAddress` looks equivalent and silently isn't:
// the keychain stops filling the pair and stops offering to save it.
precondition(
    authView.contains(".textContentType(.username)")
        && authView.contains(".textContentType(.password)")
        && !authView.contains(".textContentType(.emailAddress)"),
    "The login form's username field must use .username so Password AutoFill pairs it"
)
// Both sign-in paths share one busy condition. If the email button were gated
// on `isBusy` alone it would stay tappable while an Apple authorization is in
// flight, and starting one there discards the Apple result.
precondition(
    authView.components(separatedBy: ".disabled(auth.isBusy || isAuthorizingApple)").count == 3,
    "Both the email and Apple sign-in buttons must be disabled while either path is in flight"
)
precondition(
    authProtocol.contains("func signIn(email: String, password: String) async throws -> AuthedUser")
        && !authProtocol.contains("#if DEBUG\n    func signIn(email:")
        && cloudE2E.contains("#if DEBUG")
        && cloudE2E.contains("auth.signIn(email: email, password: password)"),
    "Email sign-in must be available to the production auth provider"
)
precondition(
    entitlements.contains("<key>com.apple.developer.applesignin</key>")
        && entitlements.contains("<string>Default</string>"),
    "The main app must declare the Sign in with Apple entitlement"
)
precondition(
    localizable.contains("\"auth.error.apple_authorization_failed\"")
        && localizable.contains("\"auth.error.sign_in_failed\"")
        && localizable.contains("\"auth.email.placeholder\"")
        && localizable.contains("\"auth.password.placeholder\"")
        && localizable.contains("\"auth.sign_in\"")
        && localizable.contains("\"auth.signing_in\"")
        // An empty form never reached the network, so it must not be reported
        // with the same copy as a credential rejection.
        && localizable.contains("\"auth.error.missing_fields\""),
    "Release localization must contain both Apple and email sign-in copy"
)

print("apple_login_ui_contract_test passed")
