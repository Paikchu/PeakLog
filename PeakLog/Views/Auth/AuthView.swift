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
                    Text("Your AI Gym Logger")
                        .font(.subheadline)
                        .foregroundColor(.textSecondary)
                }
                .padding(.bottom, 48)

                // Form
                VStack(spacing: 16) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color.appCard)
                        .cornerRadius(12)
                        .foregroundColor(.textPrimary)

                    SecureField("Password", text: $password)
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

                    Button(action: { Task { await submit() } }) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.85)
                            } else {
                                Text(isSignUp ? "Create Account" : "Sign In")
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
                    } label: {
                        Text(isSignUp ? "Already have an account? Sign In" : "New here? Create Account")
                            .font(.subheadline)
                            .foregroundColor(.textSecondary)
                    }
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func submit() async {
        guard !email.isEmpty, !password.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        do {
            if isSignUp {
                try await supabase.auth.signUp(email: email, password: password)
            } else {
                try await supabase.auth.signIn(email: email, password: password)
            }
            // authState observer in PeakLogApp will handle the transition
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

#Preview {
    AuthView()
        .environmentObject(ThemeManager())
        .environmentObject(AuthStateManager())
        .preferredColorScheme(.dark)
}
