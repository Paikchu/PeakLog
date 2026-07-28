import AuthenticationServices
import SwiftUI

struct AuthView: View {
    @ObservedObject var auth: AuthStateManager

    @Environment(\.colorScheme) private var colorScheme
    @State private var currentNonce: AppleSignInNonce?
    @State private var isAuthorizingApple = false

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

            if let message = auth.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

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
        .animation(.easeInOut(duration: 0.2), value: auth.errorMessage)
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

#Preview {
    AuthView(auth: AuthStateManager(provider: SupabaseAuthProvider()))
}
