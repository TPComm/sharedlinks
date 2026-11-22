import LinksKit
import PhotosUI
import SwiftUI

/// Add a stable case in display order, its page content below, and a UI test assertion.
enum FeatureTour: String, CaseIterable, Identifiable {
    case profilePhoto, rollup, swipeQueue

    var id: String { rawValue }

    struct Page {
        let symbol: String
        let title: String
        let body: String
        let action: Action?
    }

    enum Action {
        case profilePhoto, openURL(String, String)
    }

    var page: Page {
        switch self {
        case .profilePhoto:
            Page(symbol: "person.crop.circle", title: "Make Links Yours",
                 body: "Your profile photo now appears next to the links you send. Add a photo so your friends can spot you at a glance.",
                 action: .profilePhoto)
        case .rollup:
            Page(symbol: "bubble.left.and.bubble.right", title: "Send Today's Links Together",
                 body: "Share the links you sent in Links today as one message. In Messages, open a conversation, tap + → Links (under More if needed), then Send today's links. Pick a chat to insert a draft, then send it to your friend.",
                 action: .openURL("Open Messages", "sms:"))
        case .swipeQueue:
            Page(symbol: "rectangle.stack", title: "Swipe Through Your Queue",
                 body: "Tap the stack button at the top of your Queue to go through your links one at a time. Swipe up for the next one, and each link you swipe past moves to Seen.",
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
            case nil:
                EmptyView()
            }
        }
        .buttonStyle(.bordered)
        .disabled(savingPhoto)
        .accessibilityIdentifier("featureTour.action.\(tour.id)")
    }
}
