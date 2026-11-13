import AuthenticationServices
import LinksKit
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppGlyph(size: 104)
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

/// The app icon's play glyph on its pink-to-purple gradient.
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.22, blue: 0.37),
                                          Color(red: 0.47, green: 0.24, blue: 0.86)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.03)
            }
            .shadow(color: Color(red: 0.6, green: 0.2, blue: 0.6).opacity(0.3), radius: 16, y: 8)
            .accessibilityHidden(true)
    }
}
