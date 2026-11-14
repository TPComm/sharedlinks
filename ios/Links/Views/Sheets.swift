import LinksKit
import SwiftUI

struct AddLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var note = ""
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    init(prefill: String) {
        _text = State(initialValue: prefill)
    }

    private var detected: URL? { LinkText.firstURL(in: text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste a TikTok or Reel link", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .accessibilityIdentifier("addLink.text")
                    // The system paste control: no "Allow Paste" prompt.
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            text = strings.first ?? ""
                            focused = false
                        }
                    }
                    .labelStyle(.titleAndIcon)
                } footer: {
                    if let url = detected, url.absoluteString != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                        Text("Found a link to \(url.host() ?? "a website").")
                    } else {
                        Text("Paste the whole message if you like. The link gets pulled out automatically.")
                    }
                }
                Section {
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                        .accessibilityIdentifier("addLink.note")
                } footer: {
                    let people = model.inbox.otherPeople.map(\.name)
                    if !people.isEmpty { Text("Goes to \(LinkFormat.names(people)).") }
                }
            }
            .navigationTitle("New Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sending = true
                        Task {
                            do {
                                try await model.send(text, note: note)
                                dismiss()
                            } catch {
                                failure = error.localizedDescription
                            }
                            sending = false
                        }
                    }
                    .disabled(detected == nil || sending)
                    .accessibilityIdentifier("addLink.send")
                }
            }
            .failureAlert($failure)
        }
        .presentationDetents([.medium, .large])
        .onAppear { if text.isEmpty { focused = true } }
    }
}

struct AccountMenu: View {
    @Environment(AppModel.self) private var model
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmingDelete = false
    @State private var showingBlocked = false

    /// Spells out what goes and what stays, since none of it can come back.
    private var deleteWarning: String {
        let sent = model.inbox.links(for: .sent).count
        let links = switch sent {
        case 0: ""
        case 1: " The link you sent stays for your friends, from “Deleted user”. Delete it first if you’d rather it went too."
        default: " The \(sent) links you sent stay for your friends, from “Deleted user”. Delete them first if you’d rather they went too."
        }
        return "This permanently deletes your Links account, your watched marks and your reactions.\(links) "
            + "This can't be undone."
    }

    var body: some View {
        Menu {
            Section(model.me?.email ?? "") {
                Button("Change Display Name", systemImage: "pencil") {
                    nameDraft = model.me?.name ?? ""
                    renaming = true
                }
                if !model.claimable.isEmpty {
                    Button("Claim Earlier Links…", systemImage: "clock.arrow.circlepath") {
                        model.showClaimSheet = true
                    }
                }
            }
            Section {
                Button("How to Share to Links", systemImage: "square.and.arrow.up") {
                    model.startTour(at: .shareSheet)
                }
                Button("Show Tour Again", systemImage: "sparkles") {
                    model.startTour()
                }
            }
            Section {
                Button("Blocked People…", systemImage: "hand.raised") {
                    showingBlocked = true
                }
                if let support = LinksConfig.supportURL {
                    ContactSupportButton(url: support)
                }
                Link(destination: LinksConfig.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "lock.shield")
                }
            }
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await model.signOut() }
            }
            Button("Delete Account…", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                confirmingDelete = true
            }
        } label: {
            if model.isDeletingAccount {
                ProgressView()
                    .accessibilityLabel("Deleting account")
            } else {
                AvatarView(user: model.me, size: 30)
                    .accessibilityLabel("Account")
            }
        }
        .disabled(model.isDeletingAccount)
        .accessibilityIdentifier("account")
        .sheet(isPresented: $showingBlocked) {
            BlockedPeopleSheet().environment(model)
        }
        .alert("Delete Your Account?", isPresented: $confirmingDelete) {
            Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteWarning)
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

/// Shown after the first sign-in when the database has people from before accounts existed.
struct ClaimSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var claiming = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.claimable) { person in
                        Button {
                            claiming = true
                            Task {
                                do {
                                    try await model.claim(person)
                                } catch {
                                    failure = error.localizedDescription
                                }
                                claiming = false
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(user: person, size: 36)
                                Text(person.name).foregroundStyle(.primary)
                            }
                        }
                        .disabled(claiming)
                    }
                } header: {
                    Text("Links were shared here before sign-in. Were you one of these people?")
                        .textCase(nil)
                } footer: {
                    Text("Their links, watched marks and reactions move to your account, and you take that name.")
                }
            }
            .navigationTitle("Welcome to Links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("None of These") { dismiss() }
                }
            }
            .failureAlert($failure)
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// The app's "Couldn't Do That" alert, for a sheet to show over itself. RootView's alert
    /// (model.errorMessage) can't be used from a sheet: presenting it closes the sheet.
    func failureAlert(_ message: Binding<String?>) -> some View {
        alert("Couldn't Do That", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
