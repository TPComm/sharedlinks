import LinksKit
import SwiftUI
import UIKit
import UserNotifications

/// The tour's pages, in order. Inviting a friend (#5) goes after shareSheet once invites exist.
enum TourPage: Int, CaseIterable, Identifiable {
    case welcome, shareSheet, tabs, extras
    var id: Self { self }
}

/// The welcome tour (#10): a few pages shown once after the first sign-in (after the claim sheet,
/// if that appears), and again from the profile. Any page can be skipped. The share-sheet
/// page (#9) ticks itself off when the Share Extension reports that it has been opened.
struct TourView: View {
    @Environment(AppModel.self) private var model
    @State private var page: TourPage
    /// Links has been opened from a share sheet: the Share Extension sets this in the App Group.
    @State private var foundLinks = Onboarding.shared.hasOpenedShareExtension

    init(start: TourPage) {
        _page = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Its own row, so pages scroll under it rather than behind Skip. Kept (empty) on the
            // last page, so the pages don't jump.
            HStack {
                Spacer()
                if page != .extras {
                    Button("Skip") { model.finishTour() }
                        .fontWeight(.semibold)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Skip Tour")
                        .accessibilityIdentifier("tour.skip")
                }
            }
            .frame(minHeight: 44)
            TabView(selection: $page) {
                WelcomePage().tag(TourPage.welcome)
                ShareSheetPage(found: foundLinks).tag(TourPage.shareSheet)
                TabsPage().tag(TourPage.tabs)
                ExtrasPage().tag(TourPage.extras)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .clipped()
            controls
        }
        .background { SignInBackground() }
        .task(id: page) { await watchForShareExtension() }
        .sensoryFeedback(.success, trigger: foundLinks) { old, new in !old && new }
    }

    /// Fixed under the pages, so the buttons stay put while the pages swipe.
    private var controls: some View {
        VStack(spacing: 12) {
            PageDots(current: page)
                .padding(.bottom, 4)
            primaryButton
            secondaryButton
                .frame(minHeight: 44)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .fontWeight(.semibold)
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    @ViewBuilder private var primaryButton: some View {
        switch page {
        case .shareSheet:
            // Try It Now stays (hidden) once the step ticks off. That happens while its share sheet
            // and the Share Extension are still up, and taking away the view that presented them
            // closes the extension under the person's finger.
            ZStack {
                ShareLink(item: Onboarding.practiceURL, preview: Self.practicePreview) {
                    Text("Try It Now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .opacity(foundLinks ? 0 : 1)
                .allowsHitTesting(!foundLinks)
                .accessibilityHidden(foundLinks)
                .accessibilityIdentifier("tour.tryIt")
                if foundLinks { continueButton }
            }
        case .extras:
            Button { model.finishTour() } label: {
                Text("Start Using Links").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("tour.done")
        default:
            continueButton
        }
    }

    private var continueButton: some View {
        Button(action: advance) {
            Text("Continue").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("tour.continue")
    }

    @ViewBuilder private var secondaryButton: some View {
        switch page {
        case .shareSheet where !foundLinks:
            Button("Not Now", action: advance)
                .accessibilityIdentifier("tour.notNow")
        case .shareSheet:
            ShareLink(item: Onboarding.practiceURL, preview: Self.practicePreview) {
                Text("Try It Again")
            }
            .accessibilityIdentifier("tour.tryAgain")
        default:
            Color.clear.frame(height: 1)
        }
    }

    private func advance() {
        guard let next = TourPage(rawValue: page.rawValue + 1) else { return model.finishTour() }
        withAnimation { page = next }
    }

    /// The Share Extension runs in a process of its own and only writes a flag, so look for it
    /// every second while the share-sheet page is up (with the practice share sheet over it).
    private func watchForShareExtension() async {
        guard page == .shareSheet else { return }
        while !foundLinks, !Task.isCancelled {
            if Onboarding.shared.hasOpenedShareExtension {
                withAnimation(.spring(duration: 0.45)) { foundLinks = true }
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// What the practice share sheet shows at its top.
    private static let practicePreview = SharePreview("Practice link: share it to Links", image: practiceIcon)

    private static var practiceIcon: Image {
        let renderer = ImageRenderer(content: BrandMarkIcon(size: 120))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "link")
    }
}

// MARK: Pages

private struct WelcomePage: View {
    var body: some View {
        TourPageLayout(
            title: "Welcome to Links",
            message: "One shared inbox for articles, videos, recipes, gift ideas and more. Share any link, react, and see who's seen it."
        ) {
            MiniInbox()
        } details: {
            TrademarkNotice(alignment: .center)
        }
    }
}

private struct ShareSheetPage: View {
    let found: Bool

    var body: some View {
        TourPageLayout(
            title: found ? "Links Is in Your Share Sheet" : "Add Links to Your Share Sheet",
            message: found
                ? "Nice. If it was hiding behind More, these steps bring it to the front."
                : "Then sending any link takes two taps. iOS puts new apps at the end of the list, so bring Links to the front."
        ) {
            MiniShareSheet(found: found)
        } details: {
            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, text: "On an article, video, post or any page, tap **Share**. If the app opens its own menu, tap **More** or \(Image(systemName: "square.and.arrow.up")) there.")
                Step(number: 2, text: "Scroll the row of apps to the end and tap \(Image(systemName: "ellipsis")) **More**.")
                Step(number: 3, text: "Tap **Edit**, then \(Text(Image(systemName: "plus.circle.fill")).foregroundStyle(.green)) next to **Links**.")
                // Newer iOS shows Done as a checkmark; iOS 18 spells it out.
                Step(number: 4, text: "Drag \(Image(systemName: "line.3.horizontal")) to move Links to the top of **Favorites**, then tap **Done** (\(Image(systemName: "checkmark"))).")
                if !found {
                    Text("**Try It Now** opens a share sheet with a practice link, so nothing gets sent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                Text("You can also paste a link with \(Image(systemName: "plus")) in Links, or use **Send Link** in Shortcuts or on the Action button.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TrademarkNotice()
                    .padding(.top, 4)
            }
        }
    }
}

private struct TabsPage: View {
    var body: some View {
        TourPageLayout(
            title: "Your Inbox, Sorted",
            message: "Everything you and your friends share lands in one place."
        ) {
            MiniTabs()
        } details: {
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "play.rectangle.on.rectangle", title: "To Watch",
                        text: "What friends sent that you haven't seen yet. The badge counts them.")
                Feature(symbol: "checkmark.circle", title: "Watched",
                        text: "Everything you've seen, to find again.")
                Feature(symbol: "paperplane", title: "Sent",
                        text: "What you've shared, and who's seen it.")
                Feature(symbol: "magnifyingglass", title: "Search",
                        text: "Finds links by title, person or note.")
            }
        }
    }
}

private struct ExtrasPage: View {
    var body: some View {
        TourPageLayout(
            title: "A Couple of Extras",
            message: "Both optional, and you can set them up any time."
        ) {
            MiniHomeScreen()
        } details: {
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "square.grid.2x2", title: "Home Screen Widget",
                        text: "Touch and hold the Home Screen, tap **Edit**, then **Add Widget**, and search for Links. Mark links as seen right from it.")
                Feature(symbol: "bell.badge", title: "Notifications",
                        text: "Get notified when friends send you something, and see how many are waiting on the app icon.") {
                    NotificationsButton()
                }
            }
        }
    }
}

// MARK: Layout

/// One page: a picture, a title, a line or two, then the page's own details. Scrolls when the text
/// is too big to fit; the picture is left out at accessibility text sizes.
private struct TourPageLayout<Art: View, Details: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var art: Art
    @ViewBuilder var details: Details
    @Environment(\.dynamicTypeSize) private var typeSize
    private static var artGap: CGFloat { 24 }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if !typeSize.isAccessibilitySize {
                        art
                            .shrunkToFit(height: min(220, proxy.size.height * 0.34), spill: Self.artGap)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, Self.artGap)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                    details
                        .padding(.top, 24)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey
    @ScaledMetric(relativeTo: .subheadline) private var badge: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: badge, height: badge)
                .background(Color.accentColor, in: .circle)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Feature<Accessory: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            accessory
        }
    }
}

extension Feature where Accessory == EmptyView {
    init(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) {
        self.init(symbol: symbol, title: title, text: text) { EmptyView() }
    }
}

private struct PageDots: View {
    let current: TourPage

    var body: some View {
        HStack(spacing: 7) {
            ForEach(TourPage.allCases) { page in
                Capsule()
                    .fill(page == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: page == current ? 20 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current.rawValue + 1) of \(TourPage.allCases.count)")
    }
}

/// Turns on notifications, or says they're on, or opens Settings (iOS only asks once, so people
/// who answered the old badge-only prompt turn alerts on there). Whoever skips this is asked when
/// the tour ends.
private struct NotificationsButton: View {
    @Environment(\.openURL) private var openURL
    @State private var status: UNAuthorizationStatus?
    @State private var alertsOn = false

    var body: some View {
        Group {
            switch status {
            case nil:
                // Not EmptyView: the .task below never runs on one.
                Color.clear.frame(width: 1, height: 1)
            case .notDetermined?:
                Button("Turn On") { Task { await turnOn() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("tour.notifications")
            default:
                if alertsOn {
                    Label("On", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    Button("Settings") { openURL(url) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.small)
        .fontWeight(.semibold)
        .task { await load() }
    }

    private func load() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        alertsOn = settings.alertSetting == .enabled
    }

    private func turnOn() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await load()
    }
}

// MARK: Pictures
// Drawn rather than recorded, so they follow dark mode and the accent colour. Hidden from
// VoiceOver: the text on each page says the same.

private struct MiniInbox: View {
    var body: some View {
        VStack(spacing: 0) {
            MiniRow(platform: .tiktok, from: "Sam", title: "Wait for the drop", unread: true)
            Divider().padding(.leading, 68)
            MiniRow(platform: .instagram, from: "Alex", title: "This recipe is unreal", reaction: "😂 You")
            Divider().padding(.leading, 68)
            MiniRow(platform: .youtube, from: "You", title: "Best ten seconds online", receipt: "Seen by Sam")
        }
        // The dividers would otherwise stretch the card past its rows on wide screens.
        .frame(maxWidth: 330)
        .padding(.vertical, 4)
        .miniCard()
        .overlay(alignment: .topTrailing) { Bubble(emoji: "❤️").offset(x: 14, y: -18) }
        .overlay(alignment: .bottomLeading) { Bubble(emoji: "🔥").offset(x: -12, y: 16) }
    }
}

private struct MiniShareSheet: View {
    let found: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ThumbnailImage(platform: .tiktok, image: nil, cornerRadius: 6)
                    .frame(width: 30, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wait for the drop").font(.footnote.weight(.semibold))
                    Text("example.com").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.secondary.opacity(0.15), in: .circle)
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                AppSlot(name: "Links") {
                    BrandMarkIcon(size: 50)
                        .padding(3)
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: 2.5)
                                .phaseAnimator(reduceMotion || found ? [false] : [false, true]) { ring, grown in
                                    ring.scaleEffect(grown ? 1.08 : 1).opacity(grown ? 0.5 : 1)
                                } animation: { _ in .easeInOut(duration: 0.9) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if found {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .offset(x: 8, y: -8)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                }
                AppSlot(name: "Messages") { AppTile(color: .green, symbol: "message.fill") }
                AppSlot(name: "Mail") { AppTile(color: .blue, symbol: "envelope.fill") }
                AppSlot(name: "More") {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay { Image(systemName: "ellipsis").font(.title3.weight(.bold)) }
                        .frame(width: 50, height: 50)
                        .padding(3)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 330)
        .miniCard()
    }
}

private struct MiniTabs: View {
    var body: some View {
        VStack(spacing: 16) {
            MiniRow(platform: .youtube, from: "You", title: "Best ten seconds online", receipt: "Seen by Sam and Alex")
                .padding(.vertical, 4)
                .miniCard()
            HStack(spacing: 2) {
                MiniTab(title: "To Watch", symbol: "play.rectangle.on.rectangle", badge: 2, selected: true)
                MiniTab(title: "Watched", symbol: "checkmark.circle")
                MiniTab(title: "Sent", symbol: "paperplane")
            }
            .padding(5)
            .frame(maxWidth: 300)
            .background(Color(.secondarySystemGroupedBackground), in: .capsule)
            .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
        }
    }
}

private struct MiniHomeScreen: View {
    var body: some View {
        HStack(spacing: 26) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("2").font(.system(size: 34, weight: .bold, design: .rounded))
                    Spacer()
                    Image(systemName: "play.fill").font(.subheadline.weight(.semibold))
                }
                Text("to see").font(.footnote.weight(.semibold)).opacity(0.85)
                Spacer(minLength: 0)
                Text("Wait for the drop").font(.footnote.weight(.semibold)).lineLimit(1)
                Text("from Sam").font(.caption).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: 150, height: 150, alignment: .leading)
            .background(Color.linksSurface, in: .rect(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)

            VStack(spacing: 6) {
                BrandMarkIcon(size: 76)
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                    .overlay(alignment: .topTrailing) {
                        Text("2")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 28, minHeight: 28)
                            .background(.red, in: .circle)
                            .offset(x: 10, y: -10)
                    }
                Text("Links").font(.caption)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

private struct MiniRow: View {
    let platform: Platform
    let from: String
    let title: String
    var unread = false
    var reaction: String?
    var receipt: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(unread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
            ThumbnailImage(platform: platform, image: nil, cornerRadius: 6)
                .frame(width: 36, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    PlatformBadge(platform: platform)
                    Text(from).font(.caption).foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.subheadline.weight(unread ? .semibold : .regular))
                    .lineLimit(1)
                if let reaction {
                    Text(reaction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.16), in: .capsule)
                }
                if let receipt {
                    Text("\(Image(systemName: "checkmark")) \(receipt)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 330)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

private struct MiniTab: View {
    let title: String
    let symbol: String
    var badge = 0
    var selected = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.title3)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(.red, in: .circle)
                            .offset(x: 10, y: -6)
                    }
                }
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(selected ? Color.secondary.opacity(0.12) : .clear, in: .capsule)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

private struct AppSlot<Icon: View>: View {
    let name: String
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(spacing: 6) {
            icon
            Text(name).font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

private struct AppTile: View {
    let color: Color
    let symbol: String

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color.gradient)
            .overlay { Image(systemName: symbol).font(.title2).foregroundStyle(.white) }
            .frame(width: 50, height: 50)
            .padding(3)
    }
}

private struct Bubble: View {
    let emoji: String

    var body: some View {
        Text(emoji)
            .font(.system(size: 24))
            .frame(width: 46, height: 46)
            .background(Color(.secondarySystemGroupedBackground), in: .circle)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

/// Shrinks a picture that would spill over the title below it (short or wide windows, like an
/// unfolded iPhone Duo, leave little height for it). A picture centred in its slot may run up to
/// `spill` past each edge, into the gap above the title, before it's shrunk.
private struct ShrunkToFitHeight: ViewModifier {
    let height: CGFloat
    let spill: CGFloat
    @State private var natural: CGFloat = 0

    func body(content: Content) -> some View {
        let room = height + 2 * spill
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
            .scaleEffect(natural > room ? room / natural : 1)
            .frame(height: height)
    }
}

private extension View {
    func shrunkToFit(height: CGFloat, spill: CGFloat) -> some View {
        modifier(ShrunkToFitHeight(height: height, spill: spill))
    }

    func miniCard() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 18, y: 8)
    }
}
