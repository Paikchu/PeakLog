import SwiftUI

/// Development-era sign-in: email + password against Supabase Auth. No sign-up
/// flow — accounts are provisioned in the Supabase dashboard (Phase 0 §3).
/// A Sign in with Apple button lands here later without touching the gate.
struct AuthView: View {
    @ObservedObject var auth: AuthStateManager

    @State private var email: String = ""
    @State private var password: String = ""
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("auth.title")
                    .appFont(size: 34, weight: .bold, design: .rounded)
                    .foregroundStyle(Color.textPrimary)
                Text("auth.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }

            VStack(spacing: 12) {
                TextField("auth.email.placeholder", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                    .fieldStyle()

                SecureField("auth.password.placeholder", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await submit() } }
                    .fieldStyle()
            }

            if let message = auth.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            Button {
                Task { await submit() }
            } label: {
                Group {
                    if auth.isBusy {
                        Text("auth.signing_in")
                    } else {
                        Text("auth.sign_in")
                    }
                }
                .font(.headline)
                .foregroundStyle(Color.appBackground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentPrimary, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(auth.isBusy)

            #if DEBUG
            Button {
                auth.enterLocalMode()
            } label: {
                Text("auth.dev.skip")
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.top, 4)
            #endif

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: auth.errorMessage)
    }

    private func submit() async {
        focusedField = nil
        await auth.signIn(email: email, password: password)
    }
}

private extension View {
    func fieldStyle() -> some View {
        font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.appCard, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.appSeparator, lineWidth: 1)
            )
    }
}

#Preview {
    AuthView(auth: AuthStateManager(provider: SupabaseAuthProvider()))
}
