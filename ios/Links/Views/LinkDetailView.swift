import LinksKit
import SwiftUI

/// A link's own page, pushed when its row is tapped or its widget row opens the app: the preview,
/// who sent it and why, the button that opens it in TikTok (or wherever), reactions, and who has
/// seen it. Opening it from here marks it watched; the page stays underneath, with Mark as Not
/// Watched to undo.
struct LinkDetailView: View {
    @Environment(AppModel.self) private var model
    let linkID: Int

    var body: some View {
        if let link = model.inbox.links.first(where: { $0.id == linkID }) {
            LinkPage(link: link)
        } else {
            // Someone deleted it while this page was open (or while the app was away), or I
            // reported it or blocked its sender on another device.
            ContentUnavailableView("Link Deleted", systemImage: "trash",
                                   description: Text("This link isn't in Links anymore."))
        }
    }
}

private struct LinkPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let link: SharedLink

    @State private var editingNote = false
    @State private var noteDraft = ""
    @State private var confirmingDelete = false
    @State private var reporting = false
    @State private var blocking = false
    /// Set by Delete, Report and Block, which go back first and act once the page has gone, so
    /// the page doesn't turn into "Link Deleted" on its way out.
    @State private var afterLeaving: (@MainActor () async -> Void)?
    /// Counts reactions picked here, for the haptic (not every change is one made here).
    @State private var picks = 0

    private var inbox: InboxState { model.inbox }
    private var mine: Bool { inbox.isMine(link) }
    private var seenAt: Date? { link.seen[inbox.me] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                preview
                about
                actions
                reactions
                receipts
                // Comments (#6) go here, under the reactions.
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("linkPage.\(link.id)")
        .navigationTitle(link.platform.noun)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .animation(.default, value: seenAt)
        .sensoryFeedback(.success, trigger: seenAt) { old, new in old == nil && new != nil }
        .sensoryFeedback(.selection, trigger: picks)
        .linkDeleteConfirmation(link, isPresented: $confirmingDelete) {
            let link = link
            leave { await model.delete(link) }
        }
        .linkNoteEditor(link, isPresented: $editingNote, draft: $noteDraft)
        .linkModeration(link, reporting: $reporting, blocking: $blocking, perform: leave)
        .onDisappear {
            guard let work = afterLeaving else { return }
            afterLeaving = nil
            Task { await work() }
        }
    }

    // MARK: Sections

    /// The rich preview card, which opens the link too, with a retry when the preview failed.
    private var preview: some View {
        VStack(spacing: 10) {
            Button(action: watch) {
                RichLinkCard(link: link)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: link.isPortrait ? 300 : .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(link.platform.openTitle)
            .accessibilityIdentifier("linkPage.preview")
            if link.previewFailed {
                Button("Try Loading the Preview Again", systemImage: "arrow.clockwise") {
                    Task { await model.refreshPreview(link) }
                }
                .font(.subheadline)
                .accessibilityIdentifier("linkPage.retryPreview")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var about: some View {
        let from = mine ? "You sent this" : "From \(inbox.name(of: link.addedBy))"
        return VStack(alignment: .leading, spacing: 14) {
            // Who sent it, and their note as a message from them.
            HStack(alignment: .top, spacing: 10) {
                AvatarView(user: inbox.user(link.addedBy), size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(from) · \(LinkFormat.ago(link.addedAt))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    if !link.note.isEmpty {
                        Text(link.note)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(uiColor: .secondarySystemBackground),
                                        in: .rect(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 12) {
            if mine {
                watchButton(prominent: true)
            } else if let seenAt {
                watchButton(prominent: false)
                watchedStatus(seenAt)
            } else {
                watchButton(prominent: true)
                Button { mark(true) } label: {
                    Label("Mark as Watched", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("linkPage.markWatched")
            }
        }
    }

    @ViewBuilder private func watchButton(prominent: Bool) -> some View {
        let button = Button(action: watch) {
            Label(link.platform.openTitle, systemImage: link.platform.isVideo ? "play.fill" : "arrow.up.forward.app")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .accessibilityIdentifier("linkPage.watch")
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func watchedStatus(_ date: Date) -> some View {
        let status = Label {
            Text("Watched · \(LinkFormat.ago(date))")
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        }
        let undo = Button("Mark as Not Watched") { mark(false) }
            .accessibilityIdentifier("linkPage.markNotWatched")
        return ViewThatFits(in: .horizontal) {
            HStack { status; Spacer(); undo }
            VStack(alignment: .leading, spacing: 8) { status; undo }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reactions: some View {
        let others = link.reactions.filter { $0.key != inbox.me }.sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Reactions").font(.headline)
            ReactionBar(current: link.reactions[inbox.me]) { emoji in
                picks += 1
                Task { await model.react(link, emoji) }
            }
            .background(Color(uiColor: .secondarySystemBackground), in: .capsule)
            if !others.isEmpty {
                Text(others.map { "\($0.value) \(inbox.name(of: $0.key))" }.joined(separator: "    "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var receipts: some View {
        let receipts = self.seenBy
        if mine || !receipts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(mine ? "Seen By" : "Also Seen By").font(.headline)
                if receipts.isEmpty {
                    Text("No one else has signed in yet.").foregroundStyle(.secondary)
                }
                ForEach(receipts) { receipt in
                    HStack(spacing: 10) {
                        AvatarView(user: inbox.user(receipt.id), size: 28)
                        Text(inbox.name(of: receipt.id))
                        Spacer()
                        if let date = receipt.date {
                            Label(LinkFormat.ago(date), systemImage: "checkmark")
                                .foregroundStyle(.blue)
                        } else {
                            Text("Not yet").foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private struct Receipt: Identifiable {
        let id: String
        let date: Date?
    }

    /// Who has seen it, earliest first, apart from me and the sender. On my own links everyone
    /// else is listed, with the people who haven't seen it yet at the end.
    private var seenBy: [Receipt] {
        let seen = link.seen
            .filter { $0.key != inbox.me && $0.key != link.addedBy }
            .sorted { $0.value < $1.value }
            .map { Receipt(id: $0.key, date: $0.value) }
        guard mine else { return seen }
        // Not the people I blocked: their marks never reach me, so they'd read "Not yet" for good.
        return seen + inbox.otherPeople.filter { link.seen[$0.id] == nil && !inbox.isBlocked($0.id) }
            .map { Receipt(id: $0.id, date: nil) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ShareLink(item: link.url, subject: Text(link.displayTitle), preview: link.sharePreview)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if mine {
                    Button(link.note.isEmpty ? "Add Note" : "Edit Note", systemImage: "note.text") {
                        noteDraft = link.note
                        editingNote = true
                    }
                }
                CopyLinkButton(link: link)
                if !mine {
                    Section {
                        LinkModerationButtons(link: link, reporting: $reporting, blocking: $blocking)
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("linkPage.more")
        }
    }

    // MARK: Actions

    /// Goes back to the list, then does `work` once this page has gone.
    private func leave(_ work: @escaping @MainActor () async -> Void) {
        afterLeaving = work
        dismiss()
    }

    private func watch() {
        model.open(link, with: openURL)
    }

    private func mark(_ watched: Bool) {
        Task { await model.setSeen(link, watched) }
    }
}
