import LinksKit
import PhotosUI
import SwiftUI

/// Add a stable case in display order, its page content below, and a UI test assertion.
enum FeatureTour: String, CaseIterable, Identifiable {
    case profilePhoto, rollup, wrapped, sharedWithYou, nudge, swipeQueue, customReactions, favorites, chatInviteLink, dailyCatchUp, activity

    var id: String { rawValue }

    struct Page {
        let symbol: String
        let title: String
        let body: String
        let action: Action?
    }

    enum Action {
        case profilePhoto, openURL(String, String), favorites
    }

    var page: Page {
        switch self {
        case .wrapped:
            Page(symbol: "sparkles.rectangle.stack", title: "Links Wrapped",
                 body: "Profile → Links Wrapped shows who sent you the most links, your seen rate and your top platform. Share your highlights as a card whenever you like.",
                 action: nil)
        case .profilePhoto:
            Page(symbol: "person.crop.circle", title: "Make Links Yours",
                 body: "Your profile photo now appears next to the links you send. Add a photo so your friends can spot you at a glance.",
                 action: .profilePhoto)
        case .rollup:
            Page(symbol: "bubble.left.and.bubble.right", title: "Send Today's Links Together",
                 body: "Share the links you sent in Links today as one message. In Messages, open a conversation, tap + → Links (under More if needed), then Send today's links. Pick a chat to insert a draft, then send it to your friend.",
                 action: .openURL("Open Messages", "sms:"))
        case .sharedWithYou:
            Page(symbol: "shared.with.you", title: "See Who Shared It",
                 body: "Links friends send you in Messages now show who shared them on the link's page. Tap their name to jump back to the conversation and reply.",
                 action: nil)
        case .nudge:
            Page(symbol: "hand.wave", title: "Nudge Friends About Links They Haven't Seen",
                 body: "Open a link you sent and tap Nudge next to someone who hasn't seen it yet. You can nudge each person once per day.",
                 action: nil)
        case .swipeQueue:
            Page(symbol: "rectangle.stack", title: "Swipe Through Your Queue",
                 body: "Tap the stack button at the top of your Queue to go through your links one at a time. Swipe up for the next one, and each link you swipe past moves to Seen.",
                 action: nil)
        case .customReactions:
            Page(symbol: "face.smiling", title: "React With Any Emoji",
                 body: "Tap + after the quick reactions on a link to choose an emoji from your keyboard.",
                 action: nil)
        case .favorites:
            Page(symbol: "star.fill", title: "Save Your Favorites",
                 body: "Tap the star on any link to save it for later. Find your starred links in Favorites. Only you can see what you save.",
                 action: .favorites)
        case .chatInviteLink:
            Page(symbol: "link.badge.plus", title: "Invite Friends to a Chat",
                 body: "Open a chat's info and create an invite link. Friends already on Links who tap it join the chat. People new to Links still need a personal invite.",
                 action: nil)
        case .dailyCatchUp:
            Page(symbol: "bell.badge", title: "Get a Daily Catch-Up",
                 body: "Get one summary a day instead of a push for every new link. Turn on Daily Catch-Up in Profile → Notify Me and choose a time that suits you. It's off unless you choose it.",
                 action: nil)
        case .activity:
            Page(symbol: "bell", title: "Catch Up in Activity",
                 body: "Tap the bell to see comments, reactions and seen marks across your links together. Go through what's new and tap a comment to jump into the conversation.",
                 action: nil)
        }
    }
}

struct FeatureTourView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let tours: [FeatureTour]
    @State private var selection = 0
    @State private var choosingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var savingPhoto = false
    @State private var savedPhoto = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button("Not Now") { model.showFeatureTours = false }
                    .foregroundStyle(.primary)
                    .disabled(savingPhoto)
                    .accessibilityIdentifier("featureTour.skip")
            }
            .padding(.horizontal, 24)
            TabView(selection: $selection) {
                ForEach(Array(tours.enumerated()), id: \.element.id) { index, tour in
                    ScrollView {
                        VStack(spacing: 24) {
                            Image(systemName: tour.page.symbol)
                                .font(.system(size: 72)).foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            Text(tour.page.title).font(.largeTitle.bold())
                            Text(tour.page.body).font(.body)
                            if case .profilePhoto? = tour.page.action {
                                AvatarView(user: model.me, size: 88)
                                if savedPhoto { Label("Photo Saved", systemImage: "checkmark.circle.fill") }
                            }
                            action(for: tour)
                        }
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("featureTour.\(tour.id)")
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            if tours.count > 1 {
                PageDots(current: selection, count: tours.count)
                    .accessibilityIdentifier("featureTour.progress")
            }
            if selection == tours.count - 1 {
                Button("Done") { model.showFeatureTours = false }
                    .disabled(savingPhoto)
                    .accessibilityIdentifier("featureTour.done")
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Continue") { withAnimation { selection += 1 } }
                    .disabled(savingPhoto)
                    .accessibilityIdentifier("featureTour.continue")
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 24)
        .background { SignInBackground() }
        .interactiveDismissDisabled(savingPhoto)
        .photosPicker(isPresented: $choosingPhoto, selection: $pickedPhoto, matching: .images,
                      preferredItemEncoding: .compatible)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            savingPhoto = true
            Task {
                defer { savingPhoto = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw APIError.server("That photo couldn't be opened. Try another one.")
                    }
                    try await model.setPhoto(data)
                    savedPhoto = true
                } catch { failure = error.localizedDescription }
            }
        }
        .failureAlert($failure)
    }

    @ViewBuilder private func action(for tour: FeatureTour) -> some View {
        Group {
            switch tour.page.action {
            case .profilePhoto?:
                Button { choosingPhoto = true } label: {
                    if savingPhoto { ProgressView("Saving photo") }
                    else { Text(model.me?.avatar == nil ? "Add Profile Photo" : "Change Profile Photo") }
                }
            case .openURL(let title, let address)?:
                if let url = URL(string: address) { Button(title) { openURL(url) } }
            case .favorites?:
                Button("Open Favorites") {
                    model.paths[.favorites] = []
                    model.tab = .favorites
                    model.showFeatureTours = false
                }
            case nil:
                EmptyView()
            }
        }
        .buttonStyle(.bordered)
        .foregroundStyle(.primary)
        .disabled(savingPhoto)
        .accessibilityIdentifier("featureTour.action.\(tour.id)")
    }
}
