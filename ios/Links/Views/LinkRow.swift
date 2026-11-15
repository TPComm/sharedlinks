import LinksKit
import SwiftUI
import TipKit

struct LinkRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.gestureTipsLinkID) private var gestureTipsLinkID
    let link: SharedLink
    /// The tab whose list has this row; the link's page opens on top of it.
    let tab: InboxTab

    @State private var editingNote = false
    @State private var noteDraft = ""
    @State private var confirmingDelete = false
    @State private var reporting = false
    @State private var blocking = false
    /// The react button grows with Dynamic Type (to a point) and stays centred on the top line.
    @ScaledMetric(relativeTo: .footnote) private var scaledReactGlyph: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var topLineCenter: CGFloat = 9

    private var reactGlyph: CGFloat { min(scaledReactGlyph, 30) }
    private static let trailingInset: CGFloat = 16
    private var inbox: InboxState { model.inbox }
    private var mine: Bool { inbox.isMine(link) }
    private var seen: Bool { inbox.isSeenByMe(link) }
    private var unwatched: Bool { inbox.isUnwatched(link) }

    /// The gesture tip due on this row, if it's the one that carries them (see Tips.swift).
    private var gestureTip: (any Tip)? {
        guard gestureTipsLinkID == link.id, model.canShowTips else { return nil }
        return LinkTips.group.currentTip
    }

    var body: some View {
        Button {
            model.showPage(link, on: tab)
        } label: {
            // The row's insets live here, not in listRowInsets, so a tap anywhere in it opens it.
            content
                .padding(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: Self.trailingInset))
                .contentShape(.rect)
        }
        // Not the default style: in a List that makes the whole row one button, which then takes
        // taps meant for the react button on top of it.
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("link.\(link.id)")
        .accessibilityAction(named: seen ? "Mark as Unseen" : "Mark as Seen") {
            Task { await model.setSeen(link, !seen) }
        }
        // After the accessibility settings above, so it isn't merged into the row's element.
        .overlay(alignment: .topTrailing) {
            // The capsule is centred on the top line (below the 10pt padding) and ends where the
            // text column does. Its tap area runs from the row's top to its trailing edge and is
            // at least 48pt tall, all inside the row: taps above a row's top go to the row above.
            let capsule = ReactButton.capsule(reactGlyph)
            let top = 10 + topLineCenter - capsule.height / 2
            ReactButton(link: link, glyph: reactGlyph,
                        tapInsets: EdgeInsets(top: top, leading: 12,
                                              bottom: max(8, 48 - top - capsule.height),
                                              trailing: Self.trailingInset))
                .gestureTip(gestureTip as? ReactTip)
        }
        .gestureTip(gestureTip is ReactTip ? nil : gestureTip)
        .listRowInsets(EdgeInsets())
        .swipeActions(edge: .leading) {
            if !mine {
                Button {
                    SwipeToWatchTip().invalidate(reason: .actionPerformed)
                    Task { await model.setSeen(link, !seen) }
                } label: {
                    Label(seen ? "Unseen" : "Seen", systemImage: seen ? "circle" : "checkmark.circle.fill")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            // Not role: .destructive: that makes the List remove the row at once, taking the
            // confirmation below with it, so nothing would be deleted.
            Button { confirmingDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            ShareLink(item: link.shareableURL, subject: Text(link.displayTitle), preview: link.sharePreview) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.indigo)
        }
        // The preview is hosted in its own view graph, which doesn't inherit AppModel; without
        // it ThumbnailView's @Environment lookup crashes on every long-press.
        .contextMenu { menu } preview: { LinkPreviewCard(link: link).environment(model) }
        .linkDeleteConfirmation(link, isPresented: $confirmingDelete) { Task { await model.delete(link) } }
        .linkNoteEditor(link, isPresented: $editingNote, draft: $noteDraft)
        .linkModeration(link, reporting: $reporting, blocking: $blocking) { work in Task { await work() } }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(unwatched ? Color.accentColor : .clear)
                .frame(width: 9, height: 9)
                .padding(.top, 36)
                .accessibilityLabel(unwatched ? "Unseen" : "")
            ThumbnailView(link: link)
                .frame(width: 60, height: 80)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    PlatformBadge(platform: link.platform)
                    Text(fromLine).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(LinkFormat.ago(link.addedAt))
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.trailing, ReactButton.capsule(reactGlyph).width + 2) // room for ReactButton

                if link.isLoadingPreview {
                    Text("Loading preview title")
                        .redacted(reason: .placeholder)
                } else {
                    Text(link.displayTitle)
                        .fontWeight(unwatched ? .semibold : .regular)
                        .lineLimit(2)
                }
                if !link.note.isEmpty {
                    Text(link.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                footer
                if link.commentCount > 0 {
                    let unread = model.hasUnreadComments(link)
                    Label("\(link.commentCount) \(link.commentCount == 1 ? "comment" : "comments")\(unread ? " · New" : "")",
                          systemImage: unread ? "bubble.left.fill" : "bubble.left")
                        .font(.footnote.weight(unread ? .bold : .regular))
                        .foregroundStyle(unread ? Color.accentColor : .secondary)
                        .accessibilityIdentifier("comments.count.\(link.id)")
                }
            }
        }
        .contentShape(.rect)
    }

    private var fromLine: String {
        let from = mine ? "You" : inbox.name(of: link.addedBy)
        return [from, link.author].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var footer: some View {
        let others = inbox.seenByOthers(link)
        let reactions = link.reactions.sorted { $0.key < $1.key }.map {
            Reaction(person: $0.key, text: "\($0.value) \($0.key == inbox.me ? "You" : inbox.name(of: $0.key))",
                     mine: $0.key == inbox.me)
        }
        if mine || !others.isEmpty || !reactions.isEmpty {
            // One line when it fits. Otherwise the chips go under the "seen" text, side by side if
            // they fit and stacked if not, rather than truncating to an emoji and hiding who reacted.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { seenText(others); chips(reactions) }
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 4) {
                    seenText(others)
                    if !reactions.isEmpty {
                        // Decided by the chips' own width, whatever the seen text does above.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { chips(reactions) }.lineLimit(1)
                            VStack(alignment: .leading, spacing: 4) { chips(reactions) }
                        }
                    }
                }
            }
            .font(.footnote)
            .padding(.top, 2)
        }
    }

    /// A chip under the link; `person` is the identity, since two people's chips can read the same.
    private struct Reaction {
        let person: String
        let text: String
        let mine: Bool
    }

    @ViewBuilder private func seenText(_ others: [String]) -> some View {
        if mine {
            if others.isEmpty {
                Text("Not seen yet").foregroundStyle(.secondary)
            } else {
                Text("\(Image(systemName: "checkmark")) Seen by \(LinkFormat.names(others))")
                    .foregroundStyle(.blue)
                    .fontWeight(.medium)
            }
        } else if !others.isEmpty {
            Text("Also seen by \(LinkFormat.names(others))").foregroundStyle(.secondary)
        }
    }

    private func chips(_ reactions: [Reaction]) -> some View {
        ForEach(reactions, id: \.person) { reaction in
            Text(reaction.text)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(reaction.mine ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12),
                            in: .capsule)
        }
    }

    @ViewBuilder private var menu: some View {
        // The fast path: straight out to TikTok, marking it watched (a row tap shows its page).
        Button {
            model.open(link, with: openURL)
        } label: {
            Label("Open in \(link.platform.opener)", systemImage: "arrow.up.forward.app")
        }

        Picker("React", selection: Binding(
            get: { link.reactions[inbox.me] ?? "" },
            set: { emoji in Task { await model.react(link, emoji) } })
        ) {
            ForEach(reactionEmojis, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.palette)
        if let current = link.reactions[inbox.me] {
            Button("Remove \(current)", systemImage: "face.smiling") { Task { await model.react(link, current) } }
        }

        Section {
            if !mine {
                Button {
                    Task { await model.setSeen(link, !seen) }
                } label: {
                    Label(seen ? "Mark as Unseen" : "Mark as Seen", systemImage: seen ? "circle" : "checkmark.circle")
                }
            }
            // Notes are the sender's (the server refuses anyone else's edit).
            if mine {
                Button {
                    noteDraft = link.note
                    editingNote = true
                } label: {
                    Label(link.note.isEmpty ? "Add Note" : "Edit Note", systemImage: "note.text")
                }
            }
        }

        Section {
            ShareLink(item: link.shareableURL, subject: Text(link.displayTitle), preview: link.sharePreview) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            CopyLinkButton(link: link)
        }

        if !mine {
            Section {
                LinkModerationButtons(link: link, reporting: $reporting, blocking: $blocking)
            }
        }

        Button(role: .destructive) { confirmingDelete = true } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

extension SharedLink {
    /// The title and thumbnail a share sheet shows.
    @MainActor var sharePreview: SharePreview<Image, Never> {
        let image = ThumbnailCache.cachedImage(for: self).map { Image(uiImage: $0) }
            ?? Image(systemName: "play.rectangle.fill")
        return SharePreview(displayTitle, image: image)
    }
}

struct CopyLinkButton: View {
    @Environment(AppModel.self) private var model
    let link: SharedLink

    var body: some View {
        Button {
            UIPasteboard.general.url = link.url
            model.toast = "Copied"
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }
    }
}

extension View {
    /// "Delete this TikTok for everyone?", shared by a row and a link's page.
    func linkDeleteConfirmation(_ link: SharedLink, isPresented: Binding<Bool>,
                                delete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete this \(link.platform.noun.lowercased()) for everyone?",
                           isPresented: isPresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    /// The Add Note / Edit Note alert, shared by a row and a link's page.
    func linkNoteEditor(_ link: SharedLink, isPresented: Binding<Bool>, draft: Binding<String>) -> some View {
        modifier(NoteEditor(link: link, isPresented: isPresented, draft: draft))
    }
}

private struct NoteEditor: ViewModifier {
    @Environment(AppModel.self) private var model
    let link: SharedLink
    @Binding var isPresented: Bool
    @Binding var draft: String

    func body(content: Content) -> some View {
        content.alert(link.note.isEmpty ? "Add Note" : "Edit Note", isPresented: $isPresented) {
            TextField("Note", text: $draft, axis: .vertical)
            Button("Save") { Task { await model.setNote(link, draft) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The long-press preview: a big thumbnail with the title, like Messages' link previews.
struct LinkPreviewCard: View {
    let link: SharedLink

    var body: some View {
        RichLinkCard(link: link)
            .frame(width: link.isPortrait ? 260 : 320)
    }
}

private struct ReactButton: View {
    @Environment(AppModel.self) private var model
    let link: SharedLink
    /// The smiley's point size (20 at the default text size); the rest is in proportion.
    let glyph: CGFloat
    /// Space around the capsule that still takes the tap.
    let tapInsets: EdgeInsets
    @State private var picking = false
    /// Counts this button's picks, for the haptic: not every change (a reaction from another
    /// device, a rollback) is one the person just made here.
    @State private var picks = 0

    /// The visible capsule: 36x29 at the default size.
    static func capsule(_ glyph: CGFloat) -> CGSize { CGSize(width: glyph * 16 / 9, height: glyph * 13 / 9) }

    var body: some View {
        let current = link.reactions[model.inbox.me]
        let capsule = Self.capsule(glyph)
        Button {
            picking = true
        } label: {
            Group {
                if let current {
                    Text(current)
                        .font(.system(size: glyph * 15 / 18))
                        .frame(width: capsule.width, height: capsule.height)
                        .background(Color.accentColor.opacity(0.16), in: .capsule)
                } else {
                    // Grey like the time beside it; the button style's .secondary would be a
                    // half-strength tint, about 2:1 against the row.
                    Image(systemName: "face.smiling")
                        .font(.system(size: glyph))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .frame(width: capsule.width, height: capsule.height)
                }
            }
            .padding(tapInsets)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(current.map { "Your reaction, \($0)" } ?? "React")
        .accessibilityIdentifier("react.\(link.id)")
        .sensoryFeedback(.selection, trigger: picks)
        // No arrowEdge: pinning one stops the bar flipping above the button on rows near the
        // bottom of the screen, where it would be squeezed (iOS 18.1+ respects the edge).
        .popover(isPresented: $picking) {
            ReactionBar(current: current) { emoji in
                picking = false
                picks += 1
                Task { await model.react(link, emoji) }
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// A tapback-style row of reactionEmojis. Picking the current one again removes it.
/// In a row's popover, and inline on a link's page.
struct ReactionBar: View {
    let current: String?
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(reactionEmojis, id: \.self) { emoji in
                Button {
                    pick(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 28))
                        .frame(width: 46, height: 46)
                        .background(emoji == current ? Color.accentColor.opacity(0.22) : .clear, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(PopButtonStyle())
                .accessibilityAddTraits(emoji == current ? .isSelected : [])
                .accessibilityHint(emoji == current ? "Removes your reaction" : "")
                .accessibilityIdentifier("reaction.\(emoji)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// Grows a little under the finger, like Messages' tapbacks.
private struct PopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.25 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.5), value: configuration.isPressed)
    }
}

struct PlatformBadge: View {
    let platform: Platform

    var body: some View {
        Text(platform.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(platform.badgeStyle, in: .capsule)
    }
}
