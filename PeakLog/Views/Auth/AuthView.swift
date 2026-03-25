import SwiftUI
import Supabase

struct AuthView: View {
    @EnvironmentObject private var authState: AuthStateManager
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var didRunDebugAutoSignIn = false

    private let supabase = SupabaseManager.shared.client

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text("PeakLog")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.textPrimary)
                    Text("auth.subtitle")
                        .font(.subheadline)
                        .foregroundColor(.textSecondary)
                }
                .padding(.bottom, 48)

                // Form
                VStack(spacing: 16) {
                    TextField(String(localized: "auth.email"), text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color.appCard)
                        .cornerRadius(12)
                        .foregroundColor(.textPrimary)

                    SecureField(String(localized: "auth.password"), text: $password)
                        .padding()
                        .background(Color.appCard)
                        .cornerRadius(12)
                        .foregroundColor(.textPrimary)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if let info = infoMessage {
                        Text(info)
                            .font(.caption)
                            .foregroundColor(.green)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: { Task { await submit() } }) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.85)
                            } else {
                                Text(isSignUp ? "auth.create_account" : "auth.sign_in")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.textPrimary)
                        .foregroundColor(Color.appBackground)
                        .cornerRadius(12)
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)

                    Button {
                        withAnimation { isSignUp.toggle() }
                        errorMessage = nil
                        infoMessage = nil
                    } label: {
                        Text(isSignUp ? "auth.switch_to_sign_in" : "auth.switch_to_create_account")
                            .font(.subheadline)
                            .foregroundColor(.textSecondary)
                    }
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
        .dismissKeyboardOnTap()
        .task {
            await runDebugAutoSignInIfNeeded()
        }
    }

    // MARK: - Actions

    private func submit() async {
        let normalizedEmail = normalizeEmail(email)
        guard !normalizedEmail.isEmpty, !password.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        infoMessage = nil
        email = normalizedEmail

        do {
            if isSignUp {
                try await supabase.auth.signUp(email: normalizedEmail, password: password)
                infoMessage = String(localized: "auth.account_created")
            } else {
                try await supabase.auth.signIn(email: normalizedEmail, password: password)
            }
            // authState observer in PeakLogApp will handle the transition
        } catch {
            infoMessage = nil
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    @MainActor
    private func runDebugAutoSignInIfNeeded() async {
        #if DEBUG
        guard !didRunDebugAutoSignIn else { return }

        let environment = ProcessInfo.processInfo.environment
        guard let debugEmail = environment["PEAKLOG_DEBUG_AUTH_EMAIL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let debugPassword = environment["PEAKLOG_DEBUG_AUTH_PASSWORD"],
              !debugEmail.isEmpty,
              !debugPassword.isEmpty else {
            return
        }

        didRunDebugAutoSignIn = true
        isSignUp = false
        email = debugEmail
        password = debugPassword
        try? await Task.sleep(nanoseconds: 300_000_000)
        await submit()
        #endif
    }
}

#Preview {
    AuthView()
        .environmentObject(ThemeManager())
        .environmentObject(AuthStateManager())
        .preferredColorScheme(.dark)
}
