import AuthenticationServices
import LinksKit
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            BrandMarkIcon(size: 104)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                .padding(.bottom, 28)
            Text("Links")
                .font(.largeTitle.bold())
            Text("The reels and TikToks you send each other,\nand who's watched them.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task { await model.signIn(with: webAuthenticationSession) }
                } label: {
                    Group {
                        if model.isSigningIn {
                            ProgressView()
                        } else {
                            Text("Sign In")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("signIn")

                Button("Create Account") {
                    Task { await model.signIn(with: webAuthenticationSession, signUp: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .disabled(model.isSigningIn)
            .padding(.horizontal, 24)
            Text("Sign-in is handled securely by WorkOS.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
                .padding(.bottom, 8)
        }
        .padding()
    }
}
