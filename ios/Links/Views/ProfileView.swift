import LinksKit
import SwiftUI

/// My avatar at the top of every tab, which opens my profile (#74).
struct ProfileButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false
    /// What a row asked for once the profile has closed: the tour and the claim sheet are shown
    /// from further up, which SwiftUI can't do while this sheet is still up.
    @State private var afterClose: (() -> Void)?

    var body: some View {
        Button {
            showing = true
        } label: {
            if model.isDeletingAccount {
                ProgressView()
                    .accessibilityLabel("Deleting account")
            } else {
                AvatarView(user: model.me, size: 30)
                    .accessibilityLabel("Profile")
            }
        }
        .disabled(model.isDeletingAccount)
        .accessibilityIdentifier("account")
        .sheet(isPresented: $showing, onDismiss: {
            afterClose?()
            afterClose = nil
        }) {
            ProfileSheet(afterClose: $afterClose).environment(model)
        }
    }
}

/// Who I am, my friends, the app's settings and help, and signing out or deleting the account.
struct ProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Binding var afterClose: (() -> Void)?
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmingDelete = false
    @State private var showingAbout = false

    /// Spells out what goes and what stays, since none of it can come back.
    private var deleteWarning: String {
        let sent = model.inbox.links(for: .sent).count
        let links = switch sent {
        case 0: ""
        case 1: ", the link you sent and its note (your friends lose it too)"
        default: ", the \(sent) links you sent and their notes (your friends lose them too)"
        }
        return "This permanently deletes your Links account\(links), your watched marks and your reactions. "
            + "This can't be undone."
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return info?["CFBundleVersion"].map { "\(short) (\($0))" } ?? short
    }

    private var friendCount: String {
        switch model.inbox.otherPeople.count {
        case 0: "Just you so far"
        case 1: "1 friend"
        case let count: "\(count) friends"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                header
                Section {
                    row("Change Display Name", systemImage: "pencil") {
                        nameDraft = model.me?.name ?? ""
                        renaming = true
                    }
                    if !model.claimable.isEmpty {
                        row("Claim Earlier Links…", systemImage: "clock.arrow.circlepath") {
                            close { model.showClaimSheet = true }
                        }
                    }
                }
                Section {
                    NavigationLink {
                        PeopleList()
                    } label: {
                        Label("People", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("people")
                    NavigationLink {
                        BlockedPeopleList()
                    } label: {
                        Label("Blocked People", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("blockedPeople")
                } header: {
                    Text("Friends")
                } footer: {
                    Text(friendCount)
                }
                Section("Settings") {
                    // iOS asks only once, so this is where people who said no (or only allowed the
                    // badge, before notifications) turn them on.
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        row("Notification Settings", systemImage: "bell.badge") { openURL(url) }
                    }
                    row("How to Share to Links", systemImage: "square.and.arrow.up") {
                        close { model.startTour(at: .shareSheet) }
                    }
                    row("Show Tour Again", systemImage: "sparkles") {
                        close { model.startTour() }
                    }
                }
                Section("Help") {
                    if let support = LinksConfig.supportURL {
                        ContactSupportButton(url: support)
                    }
                    Link(destination: LinksConfig.privacyPolicyURL) {
                        Label {
                            Text("Privacy Policy").foregroundStyle(Color.primary)
                        } icon: {
                            Image(systemName: "lock.shield")
                        }
                    }
                    row("About Links", systemImage: "info.circle") { showingAbout = true }
                }
                Section {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await model.signOut() }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        HStack {
                            Label("Delete Account…", systemImage: "person.crop.circle.badge.xmark")
                            if model.isDeletingAccount {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                } footer: {
                    Text("Links \(Self.version)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .disabled(model.isDeletingAccount)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Delete Your Account?", isPresented: $confirmingDelete) {
                Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteWarning)
            }
            .alert("Links \(Self.version)", isPresented: $showingAbout) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(Platform.trademarkNotice())
            }
            .alert("Display Name", isPresented: $renaming) {
                TextField("Name", text: $nameDraft)
                    .textInputAutocapitalization(.words)
                Button("Save") { Task { await model.rename(to: nameDraft) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This is what your friends see next to the links you send.")
            }
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 6) {
                AvatarView(user: model.me, size: 88)
                    .padding(.bottom, 6)
                Text(model.me?.name ?? "")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("profile.name")
                if let email = model.me?.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile.email")
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .contain)
        }
    }

    /// A settings-style row: the icon in the accent color, the title in the text color.
    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    private func close(then action: @escaping () -> Void) {
        afterClose = action
        dismiss()
    }
}
