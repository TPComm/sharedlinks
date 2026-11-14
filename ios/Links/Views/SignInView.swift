import AuthenticationServices
import LinksKit
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 46

    var body: some View {
        GeometryReader { proxy in
            // The full hero needs about 256pt; a Display Zoom iPhone SE has about 548 in all.
            let compactHero = typeSize.isAccessibilitySize || proxy.size.height < 600
            // Scrolls only when it doesn't fit (large text); otherwise the Spacers spread it out.
            ScrollView {
                content(compactHero: compactHero)
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // No text field here: another app's keyboard (iPad Split View) mustn't shrink the screen
        // into the compact layout and replay the hero's entrance.
        .ignoresSafeArea(.keyboard)
        .background { SignInBackground() }
    }

    private func content(compactHero: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer()
            if compactHero {
                BrandMarkIcon(size: 104)
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                    .padding(.bottom, 24)
            } else {
                SignInHero()
                    .padding(.bottom, 16)
            }
            Text("Links")
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
            Text("The reels and TikToks you send each other,\nand who's watched them.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            if model.pendingInvite != nil {
                Label("You’re invited. Sign in or create an account to join.", systemImage: "envelope.open")
                    .font(.callout.weight(.medium))
                    .padding(.top, 14)
                    .accessibilityIdentifier("invited")
            }
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
                .accessibilityIdentifier("signIn")

                // The frame goes on the label: on the button it widens the tap area, not the button.
                Button {
                    Task { await model.signIn(with: webAuthenticationSession, signUp: true) }
                } label: {
                    Text("Create Account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .fontWeight(.semibold)
            .disabled(model.isSigningIn)
            .frame(maxWidth: 420) // not edge to edge on iPad
            .padding(.horizontal, 24)
            Label("Sign-in is handled securely by WorkOS.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 4)
            // For people who can't sign in, too (App Store guideline 1.2: published contact information).
            if let support = LinksConfig.supportURL {
                Link(destination: support) {
                    Text("Help: \(LinksConfig.supportAddress(support))")
                }
                .font(.footnote)
                .padding(.bottom, 4)
                .accessibilityIdentifier("signIn.support")
            }
            Link("Privacy Policy", destination: LinksConfig.privacyPolicyURL)
                .font(.footnote)
                .padding(.bottom, 8)
                .accessibilityIdentifier("signIn.privacy")
        }
        .padding()
    }
}

/// The app icon with reactions and platform badges drifting around it: what the app is for.
private struct SignInHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private enum Content {
        case emoji(String)
        case platform(Platform)
    }

    private struct Bubble: Identifiable {
        let id: Int
        let content: Content
        let x: CGFloat
        let y: CGFloat
    }

    private let bubbles = [
        Bubble(id: 0, content: .emoji("❤️"), x: -104, y: -50),
        Bubble(id: 1, content: .platform(.tiktok), x: 100, y: -78),
        Bubble(id: 2, content: .emoji("😂"), x: 110, y: 34),
        Bubble(id: 3, content: .platform(.instagram), x: -98, y: 64),
        Bubble(id: 4, content: .emoji("🔥"), x: 34, y: 90),
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.linksGreen.opacity(0.3))
                .frame(width: 190, height: 190)
                .blur(radius: 50)
            BrandMarkIcon(size: 112)
                .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
            ForEach(bubbles) { bubble in
                view(for: bubble.content)
                    // With Reduce Motion they fade in, without the bouncy scale.
                    .scaleEffect(shown || reduceMotion ? 1 : 0.4)
                    .opacity(shown ? 1 : 0)
                    .animation((reduceMotion ? Animation.easeOut(duration: 0.3) : .spring(duration: 0.6, bounce: 0.45))
                               .delay(0.15 + Double(bubble.id) * 0.08), value: shown)
                    .modifier(Drift(seed: bubble.id, active: !reduceMotion))
                    .offset(x: bubble.x, y: bubble.y)
            }
        }
        .frame(height: 240)
        // Decorative (hidden from VoiceOver), and its badges are placed for this text size; larger
        // ones would run into the icon.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .onAppear { shown = true }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func view(for content: Content) -> some View {
        switch content {
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 26))
                .frame(width: 50, height: 50)
                .background(Color(.secondarySystemGroupedBackground), in: .circle)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        case .platform(let platform):
            Text(platform.label)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(platform.badgeStyle, in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
    }
}

/// A slow bob, at a different pace per bubble so they don't move in step. Off with Reduce Motion.
private struct Drift: ViewModifier {
    let seed: Int
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, up in
                view.offset(y: up ? -5 : 5)
            } animation: { _ in
                .easeInOut(duration: 2.2 + Double(seed) * 0.35)
            }
        } else {
            content
        }
    }
}

/// A wash of the icon's green from the top, fading into the normal background. (The tour too.)
struct SignInBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: [Color.linksGreen.opacity(0.22), Color.linksGreen.opacity(0)],
                           startPoint: .top, endPoint: .center)
            RadialGradient(colors: [Color.linksGreen.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.5, y: 0.32), startRadius: 10, endRadius: 320)
        }
        .ignoresSafeArea()
    }
}
