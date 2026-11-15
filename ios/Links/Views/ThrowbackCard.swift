import LinksKit
import SwiftUI

struct ThrowbackCard: View {
    @Environment(AppModel.self) private var model
    @State private var selection = 0

    var body: some View {
        let favorites = model.inbox.throwbacks(in: model.chat)
        if !favorites.isEmpty {
            let link = favorites[selection % favorites.count]
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("THROWBACK", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.orange)
                    Spacer()
                    Text(link.addedAt, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Remember this one?")
                        .font(.title2.weight(.bold))
                    Text("An old favorite you reacted to together.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.showPage(link, on: .watched)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ThumbnailView(link: link)
                            .frame(width: 76, height: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(link.displayTitle)
                                .font(.headline)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if !link.note.isEmpty {
                                Text("“\(link.note)”")
                                    .font(.subheadline)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("From \(model.inbox.name(of: link.addedBy)) · \(link.sourceName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("throwback.open")
                .accessibilityHint("Opens the original link page without changing watched status")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { reactionLabels(for: link) }
                    VStack(alignment: .leading, spacing: 6) { reactionLabels(for: link) }
                }

                if favorites.count > 1 {
                    Button {
                        selection = (selection + 1) % favorites.count
                    } label: {
                        Label("Another throwback", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("throwback.another")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(.orange.opacity(0.07).gradient)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.orange.opacity(0.2), lineWidth: 1)
            }
            .sensoryFeedback(.selection, trigger: selection)
            .accessibilityIdentifier("throwback.card")
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private func reactionLabels(for link: SharedLink) -> some View {
        reaction(name: "You", emoji: link.reactions[model.inbox.me] ?? "")
        let friends = model.inbox.throwbackFriends(of: link)
        if let friend = friends.first {
            reaction(name: friend.name, emoji: link.reactions[friend.id] ?? "")
        }
        if friends.count > 1 {
            Text("+\(friends.count - 1) more")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reaction(name: String, emoji: String) -> some View {
        Text("\(emoji) \(name)")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.background.opacity(0.7), in: .capsule)
    }
}
