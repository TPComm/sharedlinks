import SwiftUI
import LinksKit

struct TonightsPickSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let group: LinkGroup
    let openLink: (SharedLink) -> Void

    private var receiptsAvailable: Bool {
        group.members.allSatisfy {
            $0 != LinkUser.deletedID && model.inbox.user($0) != nil && !model.inbox.isBlocked($0)
        }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Tonight’s Pick", systemImage: "moon.stars.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)

                if let pick = model.inbox.tonightsPick(in: group.id) {
                    Text(pick.link.displayTitle)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("tonightsPick.title")
                    Text("\(pick.link.sourceName) · Shared by \(pick.link.addedBy == model.inbox.me ? "you" : model.inbox.name(of: pick.link.addedBy))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Still to watch (\(pick.unwatched.count)): \(LinkFormat.names(pick.unwatched.map { $0 == model.inbox.me ? "You" : model.inbox.name(of: $0) }))")
                        .font(.subheadline)
                        .accessibilityIdentifier("tonightsPick.people")
                    Button {
                        // Keep the usual link page underneath for Seen undo and reactions on return.
                        openLink(pick.link)
                        model.open(pick.link, with: openURL)
                    } label: {
                        Text(pick.link.platform.openTitle)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .accessibilityHint("Opens the original link and marks it seen for you")
                    .accessibilityIdentifier("tonightsPick.open")
                } else {
                    Text(emptyTitle)
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("tonightsPick.empty")
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
        } footer: {
            Text("The link most people here haven’t marked Seen. Based on links you can see; the sender isn’t counted. Newest breaks a tie.")
        }
    }

    private var emptyTitle: String {
        if Set(group.members).count < 2 { return "Better with company" }
        if !receiptsAvailable { return "No pick available" }
        return model.inbox.links(in: group.id).isEmpty ? "Nothing to pick yet" : "All caught up"
    }

    private var emptyMessage: String {
        if Set(group.members).count < 2 { return "Add someone to this chat to find something to watch together." }
        if !receiptsAvailable { return "A pick needs Seen status for everyone in this chat." }
        return model.inbox.links(in: group.id).isEmpty
            ? "Share a link here and we’ll find the one most people still have to watch."
            : "Everyone has marked the shared links you can see as Seen. Share something new for tonight."
    }
}
