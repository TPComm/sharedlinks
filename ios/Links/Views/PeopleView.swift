import LinksKit
import SwiftUI

/// Profile → People: the people I share a chat with, the invites I sent that nobody has used yet, and
/// Invite a Friend (#5).
struct PeopleList: View {
    @Environment(AppModel.self) private var model
    @State private var inviting = false
    @State private var failure: String?

    private var people: [LinkUser] { [model.me].compactMap { $0 } + model.inbox.otherPeople }

    var body: some View {
        List {
            Section {
                Button("Invite a Friend", systemImage: "person.badge.plus") { inviting = true }
                    .accessibilityIdentifier("inviteFriend")
            } footer: {
                if model.inbox.otherPeople.isEmpty {
                    Text("It’s just you here. Invite someone to start sharing.")
                }
            }
            Section("In Your Chats") {
                ForEach(people) { user in
                    HStack(spacing: 12) {
                        AvatarView(user: user, size: 32)
                        Text(user.name)
                        Spacer()
                        if user.id == model.me?.id {
                            Text("You").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !model.invites.isEmpty {
                Section {
                    ForEach(model.invites) { invite in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.email ?? "Invite link")
                            Text("Expires \(invite.expiresAt, format: .relative(presentation: .named))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Cancel Invite", role: .destructive) {
                                Task {
                                    do {
                                        try await model.revokeInvite(invite)
                                    } catch {
                                        failure = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Invited")
                } footer: {
                    Text("Swipe to cancel an invite. Each link works once, for a week.")
                }
            }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadInvites() }
        .refreshable {
            await model.refresh()
            await model.loadInvites()
        }
        .sheet(isPresented: $inviting) {
            InviteSheet().environment(model)
        }
        .failureAlert($failure)
    }
}

/// Makes an invite link, then hands it to the share sheet (Messages shows the invite page's preview).
struct InviteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var invite: Invite?
    @State private var creating = false
    @State private var failure: String?

    private var inviter: String { model.me?.name ?? "A friend" }
    private var chat: LinkGroup? {
        guard let group = model.inbox.group(model.chat), !group.isDirect else { return nil }
        return group
    }
    private var joining: String {
        if let chat { "They’ll join \(model.inbox.title(of: chat))." } else { "Starts a chat with just you two." }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let invite, let url = invite.url {
                    Section {
                        ShareLink(item: url,
                                  subject: Text("Join me on Links"),
                                  message: Text("Join me on Links to share articles, videos, recipes and more."),
                                  preview: SharePreview("\(inviter) invited you to Links")) {
                            Label("Send Invite", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("sendInvite")
                    } footer: {
                        if let email = invite.email {
                            Text("\(joining) The link works once, for a week. \(email) can also get in just by signing in with that address.")
                        } else {
                            Text("\(joining) The link works once, for a week.")
                        }
                    }
                } else {
                    Section {
                        TextField("Their email (optional)", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("With their email, they can get in even if the link gets lost while they install Links.")
                    }
                    Section {
                        LabeledContent("Chat", value: chat.map(model.inbox.title(of:)) ?? "Just You Two")
                            .accessibilityIdentifier("invite.chat")
                    } footer: {
                        Text(joining)
                    }
                    Section {
                        Button {
                            Task { await create() }
                        } label: {
                            if creating { ProgressView() } else { Text("Create Invite Link") }
                        }
                        .disabled(creating)
                        .accessibilityIdentifier("createInvite")
                    } footer: {
                        if let failure { Text(failure).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Invite a Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(invite == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() async {
        creating = true
        failure = nil
        defer { creating = false }
        do {
            invite = try await model.createInvite(email: email, groupID: chat?.id)
        } catch {
            failure = error.localizedDescription
        }
    }
}
