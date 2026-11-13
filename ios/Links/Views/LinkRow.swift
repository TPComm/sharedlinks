import LinksKit
import SwiftUI

struct LinkRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let link: SharedLink

    @State private var editingNote = false
    @State private var noteDraft = ""
    @State private var confirmingDelete = false
    /// The react button grows with Dynamic Type (to a point) and stays centred on the top line.
    @ScaledMetric(relativeTo: .footnote) private var scaledReactGlyph: CGFloat = 18
    @ScaledMetric(relativeTo: .footnote) private var topLineCenter: CGFloat = 9

    private var reactGlyph: CGFloat { min(scaledReactGlyph, 30) }
    private var inbox: InboxState { model.inbox }
    private var mine: Bool { inbox.isMine(link) }
    private var seen: Bool { inbox.isSeenByMe(link) }
    private var unwatched: Bool { inbox.isUnwatched(link) }

    var body: some View {
        Button {
            model.open(link, with: openURL)
        } label: {
            // The vertical insets live here, not in listRowInsets, so a tap there still opens it.
            content
                .padding(.vertical, 10)
                .contentShape(.rect)
        }
        // Not the default style: in a List that makes the whole row one button, which then takes
        // taps meant for the react button on top of it.
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("link.\(link.id)")
        .accessibilityAction(named: seen ? "Mark as Not Watched" : "Mark as Watched") {
            Task { await model.setSeen(link, !seen) }
        }
        // After the accessibility settings above, so it isn't merged into the row's element.
        .overlay(alignment: .topTrailing) {
            // Centred on the top line (below the 10pt padding), its capsule at the row's trailing edge.
            ReactButton(link: link, glyph: reactGlyph)
                .offset(x: 6, y: 10 + topLineCenter - ReactButton.frameHeight(reactGlyph) / 2)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
        .swipeActions(edge: .leading) {
            if !mine {
                Button {
                    Task { await model.setSeen(link, !seen) }
                } label: {
                    Label(seen ? "Not Watched" : "Watched", systemImage: seen ? "circle" : "checkmark.circle.fill")
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
            ShareLink(item: link.url, subject: Text(link.displayTitle), preview: sharePreview) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.indigo)
        }
        // The preview is hosted in its own view graph, which doesn't inherit AppModel; without
        // it ThumbnailView's @Environment lookup crashes on every long-press.
        .contextMenu { menu } preview: { LinkPreviewCard(link: link).environment(model) }
        .confirmationDialog("Delete this \(link.platform.noun.lowercased()) for everyone?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.delete(link) } }
        }
        .alert(link.note.isEmpty ? "Add Note" : "Edit Note", isPresented: $editingNote) {
            TextField("Note", text: $noteDraft, axis: .vertical)
            Button("Save") { Task { await model.setNote(link, noteDraft) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(unwatched ? Color.accentColor : .clear)
                .frame(width: 9, height: 9)
                .padding(.top, 36)
                .accessibilityLabel(unwatched ? "Not watched" : "")
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
        let reactions = link.reactions.sorted { $0.key < $1.key }
            .map { (text: "\($0.value) \($0.key == inbox.me ? "You" : inbox.name(of: $0.key))", mine: $0.key == inbox.me) }
        if mine || !others.isEmpty || !reactions.isEmpty {
            // One line when it fits; at large text sizes the chips go on their own line(s) rather
            // than truncating to an emoji, which would hide who reacted.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { seenText(others); chips(reactions) }
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 4) {
                    seenText(others)
                    HStack(spacing: 6) { chips(reactions) }.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 4) { seenText(others); chips(reactions) }
            }
            .font(.footnote)
            .padding(.top, 2)
        }
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

    private func chips(_ reactions: [(text: String, mine: Bool)]) -> some View {
        ForEach(reactions, id: \.text) { reaction in
            Text(reaction.text)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(reaction.mine ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12),
                            in: .capsule)
        }
    }

    @ViewBuilder private var menu: some View {
        Button {
            model.open(link, with: openURL)
        } label: {
            Label("Open in \(link.platform == .web ? "Browser" : link.platform.label)", systemImage: "arrow.up.forward.app")
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
                    Label(seen ? "Mark as Not Watched" : "Mark as Watched", systemImage: seen ? "circle" : "checkmark.circle")
                }
            }
            Button {
                noteDraft = link.note
                editingNote = true
            } label: {
                Label(link.note.isEmpty ? "Add Note" : "Edit Note", systemImage: "note.text")
            }
        }

        Section {
            ShareLink(item: link.url, subject: Text(link.displayTitle), preview: sharePreview) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.url = link.url
                model.toast = "Copied"
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
        }

        Button(role: .destructive) { confirmingDelete = true } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var sharePreview: SharePreview<Image, Never> {
        let image = ThumbnailCache.cachedImage(for: link).map { Image(uiImage: $0) }
            ?? Image(systemName: "play.rectangle.fill")
        return SharePreview(link.displayTitle, image: image)
    }
}

/// The long-press preview: a big thumbnail with the title, like Messages' link previews.
struct LinkPreviewCard: View {
    let link: SharedLink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThumbnailView(link: link, cornerRadius: 0)
                .frame(width: 280, height: 360)
            VStack(alignment: .leading, spacing: 4) {
                Text(link.displayTitle).font(.headline).lineLimit(3)
                Text(link.url.host() ?? link.url.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(width: 280)
    }
}

/// A row's reaction button, like the web app's: your emoji once you've reacted, else a smiley.
/// It opens a tapback bar of reactionEmojis (the long-press menu has the same choices).
private struct ReactButton: View {
    @Environment(AppModel.self) private var model
    let link: SharedLink
    /// The smiley's point size (18 at the default text size); the rest is in proportion.
    let glyph: CGFloat
    @State private var picking = false
    /// Counts this button's picks, for the haptic: not every change (a reaction from another
    /// device, a rollback) is one the person just made here.
    @State private var picks = 0

    /// The visible capsule: 32x26 at the default size.
    static func capsule(_ glyph: CGFloat) -> CGSize { CGSize(width: glyph * 16 / 9, height: glyph * 13 / 9) }
    /// The tap area: 6pt either side of the capsule, and at least 44pt.
    static func frameHeight(_ glyph: CGFloat) -> CGFloat { max(44, capsule(glyph).height) }

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
            .frame(width: max(44, capsule.width + 12), height: Self.frameHeight(glyph))
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
private struct ReactionBar: View {
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
