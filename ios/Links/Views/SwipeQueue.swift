import LinksKit
import SwiftUI

/// Swipe Through: the Queue one full-screen card at a time. Swiping on to the next card marks the
/// one left behind seen; going back never unmarks, and Close leaves the current card as it is.
/// The cards are a preview and Open, not the platform's own player.
struct SwipeQueueView: View {
    @Environment(AppModel.self) private var model
    let queue: SwipeQueue
    @State private var position: Int? = 0
    @State private var commentsLinkID: Int?

    private var current: Int { position ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<queue.cardCount, id: \.self) { index in
                        Group {
                            if let id = queue.linkID(at: index) {
                                card(id)
                            } else {
                                end
                            }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("swipeQueue")
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: position) { old, new in
            guard let old, let new else { return }
            for id in queue.passed(from: old, to: new) {
                guard let link = model.inbox.links.first(where: { $0.id == id }),
                      model.inbox.isUnwatched(link) else { continue }
                Task { await model.setSeen(link, true) }
            }
        }
        .sheet(isPresented: Binding(get: { commentsLinkID != nil }, set: { if !$0 { commentsLinkID = nil } })) {
            if let commentsLinkID { SwipeQueueComments(linkID: commentsLinkID) }
        }
    }

    private var header: some View {
        HStack {
            Button { model.swipeQueue = nil } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("swipeQueue.close")
            Spacer()
            if current < queue.linkIDs.count {
                Text("\(current + 1) of \(queue.linkIDs.count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: current)
                    .accessibilityIdentifier("swipeQueue.progress")
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private func card(_ id: Int) -> some View {
        if let link = model.inbox.links.first(where: { $0.id == id }) {
            SwipeQueueCard(link: link) { commentsLinkID = id }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("swipeQueue.card.\(id)")
        } else {
            // Deleted, reported or blocked since Swipe Through opened.
            ContentUnavailableView("Link Deleted", systemImage: "trash",
                                   description: Text("This link isn't in Links anymore."))
        }
    }

    private var end: some View {
        ContentUnavailableView {
            Label("All Caught Up", systemImage: "checkmark.circle")
        } description: {
            Text(queue.linkIDs.count == 1 ? "You've been through the link in your Queue."
                 : "You've been through all \(queue.linkIDs.count) links in your Queue.")
        } actions: {
            Button("Done") { model.swipeQueue = nil }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("swipeQueue.done")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swipeQueue.end")
    }
}

private struct SwipeQueueCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let link: SharedLink
    let showComments: () -> Void
    @State private var picks = 0

    private var inbox: InboxState { model.inbox }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Button { model.open(link, with: openURL) } label: {
                RichLinkCard(link: link)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: link.isPortrait ? 300 : .infinity)
            .layoutPriority(-1)
            .accessibilityElement(children: .combine)
            .accessibilityHint(link.platform.openTitle)
            about
            Button { model.open(link, with: openURL) } label: {
                Label(link.platform.openTitle, systemImage: "arrow.up.forward.app")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("swipeQueue.openLink")
            ReactionBar(current: link.reactions[inbox.me]) { emoji in
                picks += 1
                Task { await model.react(link, emoji) }
            }
            .background(Color(uiColor: .secondarySystemBackground), in: .capsule)
            Button(action: showComments) {
                Label(link.commentCount == 0 ? "Comments" : "Comments (\(link.commentCount))",
                      systemImage: "bubble.left.and.bubble.right")
            }
            .accessibilityIdentifier("swipeQueue.comments")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 600)
        .sensoryFeedback(.selection, trigger: picks)
    }

    private var about: some View {
        let chat = inbox.hasChats ? inbox.group(link.groupID).map { " in \(inbox.title(of: $0))" } : nil
        return HStack(alignment: .top, spacing: 10) {
            AvatarView(user: inbox.user(link.addedBy), size: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text("From \(inbox.name(of: link.addedBy))\(chat ?? "") · \(LinkFormat.ago(link.addedAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                if !link.note.isEmpty {
                    Text(link.note)
                        .lineLimit(4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground),
                                    in: .rect(cornerRadius: 16, style: .continuous))
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A card's comments, the same thread and composer as a link's page.
private struct SwipeQueueComments: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let linkID: Int
    @State private var thread = LinkThread()

    var body: some View {
        NavigationStack {
            ScrollView {
                CommentThreadView(thread: thread, linkID: linkID)
                    .padding(20)
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("swipeQueue.comments.done")
                }
            }
            .safeAreaInset(edge: .bottom) { CommentComposer(thread: thread, linkID: linkID) }
            .scrollDismissesKeyboard(.interactively)
            .task { await thread.load(linkID, model: model) }
            .onChange(of: model.inboxRefresh) { _, _ in
                Task { await thread.load(linkID, model: model) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
