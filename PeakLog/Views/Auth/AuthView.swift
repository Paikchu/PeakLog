import AuthenticationServices
import SwiftUI

struct AuthView: View {
    @ObservedObject var auth: AuthStateManager

    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var password = ""
    @State private var currentNonce: AppleSignInNonce?
    @State private var isAuthorizingApple = false
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
                // `.username`, not `.emailAddress`: only the former pairs with
                // `.password` for Password AutoFill, which is what lets the
                // keychain fill both fields and offer to save the credential.
                // `.emailAddress` is the address-book type and gets no pairing.
                TextField("auth.email.placeholder", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                    .fieldStyle()
                    .accessibilityIdentifier("email-field")

                SecureField("auth.password.placeholder", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await submit() } }
                    .fieldStyle()
                    .accessibilityIdentifier("password-field")
            }

            // Consumes an already-classified case, not a free-form string —
            // the redaction lives in `AuthDisplayError`, not in this view.
            if let displayError = auth.displayError {
                Text(displayError.localizedMessage)
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
            // Same condition as the Apple button below: while an Apple
            // authorization is in flight `isBusy` is still false, and starting
            // an email sign-in there would bump the generation and silently
            // discard the Apple result.
            .disabled(auth.isBusy || isAuthorizingApple)
            .accessibilityIdentifier("email-sign-in-button")

            SignInWithAppleButton(.signIn) { request in
                prepare(request)
            } onCompletion: { result in
                complete(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .id(colorScheme)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .disabled(auth.isBusy || isAuthorizingApple)
            .accessibilityIdentifier("apple-sign-in-button")

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
        .animation(.easeInOut(duration: 0.2), value: auth.displayError)
    }

    private func submit() async {
        focusedField = nil
        await auth.signIn(email: email, password: password)
    }

    private func prepare(_ request: ASAuthorizationAppleIDRequest) {
        guard !isAuthorizingApple, !auth.isBusy else { return }

        do {
            let nonce = try AppleSignInNonce.random()
            currentNonce = nonce
            isAuthorizingApple = true
            auth.clearSignInError()
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonce.hashedValue
        } catch {
            auth.reportAppleAuthorizationFailure()
        }
    }

    private func complete(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential
            handle(
                AppleAuthorizationResolver.resolve(
                    identityToken: appleCredential?.identityToken,
                    nonce: currentNonce,
                    fullName: formattedName(appleCredential?.fullName),
                    givenName: nonEmpty(appleCredential?.fullName?.givenName),
                    familyName: nonEmpty(appleCredential?.fullName?.familyName)
                )
            )

        case .failure(let error):
            handle(
                AppleAuthorizationResolver.resolve(
                    errorCode: (error as? ASAuthorizationError)?.code
                )
            )
        }
    }

    private func handle(_ resolution: AppleAuthorizationResolution) {
        currentNonce = nil
        switch resolution {
        case .credential(let credential):
            Task {
                await auth.signInWithApple(credential)
                isAuthorizingApple = false
            }
        case .cancelled:
            isAuthorizingApple = false
        case .failed:
            isAuthorizingApple = false
            auth.reportAppleAuthorizationFailure()
        }
    }

    private func formattedName(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        return nonEmpty(PersonNameComponentsFormatter().string(from: components))
    }

    private func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
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
    AuthView(auth: AuthStateManager())
}
