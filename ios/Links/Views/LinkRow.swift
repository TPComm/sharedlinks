import LinksKit
import SwiftUI

struct LinkRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let link: SharedLink

    @State private var editingNote = false
    @State private var noteDraft = ""
    @State private var confirmingDelete = false

    private var inbox: InboxState { model.inbox }
    private var mine: Bool { inbox.isMine(link) }
    private var seen: Bool { inbox.isSeenByMe(link) }
    private var unwatched: Bool { inbox.isUnwatched(link) }

    var body: some View {
        Button {
            model.open(link, with: openURL)
        } label: {
            content
        }
        .tint(.primary)
        .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 16))
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("link.\(link.id)")
        .accessibilityAction(named: seen ? "Mark as Not Watched" : "Mark as Watched") {
            Task { await model.setSeen(link, !seen) }
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
            .map { "\($0.value) \($0.key == inbox.me ? "You" : inbox.name(of: $0.key))" }
        if mine || !others.isEmpty || !reactions.isEmpty {
            HStack(spacing: 8) {
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
                if !reactions.isEmpty {
                    Text(reactions.joined(separator: "  "))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .lineLimit(1)
            .padding(.top, 2)
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
