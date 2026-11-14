import LinksKit
import SwiftUI

/// Report… and Block <name>… for someone else's link, in its row's menu and on its page.
struct LinkModerationButtons: View {
    @Environment(AppModel.self) private var model
    let link: SharedLink
    @Binding var reporting: Bool
    @Binding var blocking: Bool

    var body: some View {
        Button("Report…", systemImage: "exclamationmark.bubble") { reporting = true }
        if model.inbox.canBlock(link.addedBy) {
            Button("Block \(model.inbox.name(of: link.addedBy))…", systemImage: "hand.raised") { blocking = true }
        }
    }
}

extension View {
    /// The Report reasons and the Block confirmation that LinkModerationButtons open. `perform` runs
    /// the chosen action: at once from a row, after going back from a link's page.
    func linkModeration(_ link: SharedLink, reporting: Binding<Bool>, blocking: Binding<Bool>,
                        perform: @escaping (@escaping @MainActor () async -> Void) -> Void) -> some View {
        modifier(LinkModeration(link: link, reporting: reporting, blocking: blocking, perform: perform))
    }
}

private struct LinkModeration: ViewModifier {
    @Environment(AppModel.self) private var model
    let link: SharedLink
    @Binding var reporting: Bool
    @Binding var blocking: Bool
    let perform: (@escaping @MainActor () async -> Void) -> Void

    func body(content: Content) -> some View {
        let sender = model.inbox.user(link.addedBy)
        let name = model.inbox.name(of: link.addedBy)
        content
            .confirmationDialog("Report this \(link.platform.noun.lowercased())?", isPresented: $reporting,
                                titleVisibility: .visible) {
                ForEach(ReportReason.allCases) { reason in
                    Button(reason.title) {
                        let link = link
                        perform { await model.report(link, reason: reason) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It's hidden for you, and whoever runs Links gets your report. \(name) isn't told.")
            }
            .alert("Block \(name)?", isPresented: $blocking) {
                if let sender {
                    Button("Block", role: .destructive) {
                        perform { await model.block(sender, alsoReport: false) }
                    }
                    Button("Block and Report", role: .destructive) {
                        perform { await model.block(sender, alsoReport: true) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You won't see their links, reactions or comments. They aren't told. You can unblock them from the account menu.")
            }
    }
}

/// Account menu → Blocked People…: everyone I've blocked, each with Unblock.
struct BlockedPeopleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.inbox.blockedPeople.isEmpty {
                    ContentUnavailableView("No One Blocked", systemImage: "hand.raised",
                                           description: Text("To block someone, long-press one of their links and choose Block."))
                } else {
                    List {
                        Section {
                            ForEach(model.inbox.blockedPeople) { person in
                                HStack(spacing: 12) {
                                    AvatarView(user: person, size: 36)
                                    Text(person.name)
                                    Spacer()
                                    Button("Unblock") { Task { await model.unblock(person) } }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("unblock.\(person.id)")
                                }
                            }
                        } footer: {
                            Text("You don't see their links, reactions or comments. They aren't told.")
                        }
                    }
                }
            }
            .navigationTitle("Blocked People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Contact Support" in the account menu, with the address under it. Copies the address when
/// nothing can open it (no Mail app set up).
struct ContactSupportButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let url: URL

    var body: some View {
        let address = LinksConfig.supportAddress(url)
        Button {
            openURL(url) { opened in
                guard !opened else { return }
                UIPasteboard.general.string = address
                model.toast = "Copied \(address)"
            }
        } label: {
            Label {
                Text("Contact Support")
                Text(address)
            } icon: {
                Image(systemName: "envelope")
            }
        }
    }
}
