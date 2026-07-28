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
    !authView.contains("TextField(")
        && !authView.contains("SecureField(")
        && !authView.contains("auth.email")
        && !authView.contains("auth.password"),
    "Release login must not expose email and password controls"
)
precondition(
    authProtocol.contains("#if DEBUG\n    func signIn(email:")
        && cloudE2E.contains("#if DEBUG")
        && cloudE2E.contains("auth.signIn(email: email, password: password)"),
    "Email sign-in must remain available only to DEBUG cloud checks"
)
precondition(
    entitlements.contains("<key>com.apple.developer.applesignin</key>")
        && entitlements.contains("<string>Default</string>"),
    "The main app must declare the Sign in with Apple entitlement"
)
precondition(
    localizable.contains("\"auth.error.apple_authorization_failed\"")
        && localizable.contains("\"auth.error.sign_in_failed\"")
        && !localizable.contains("\"auth.email")
        && !localizable.contains("\"auth.password")
        && !localizable.contains("\"auth.error.invalid_credentials\"")
        && !localizable.contains("\"auth.error.missing_fields\""),
    "Release localization must contain Apple errors and no obsolete email form copy"
)

print("apple_login_ui_contract_test passed")
