import LinksKit
import SwiftUI

struct AddLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var note = ""
    @State private var sending = false
    @State private var failure: String?
    /// The chat it goes to: the one the lists show, else the default chat.
    @State private var groupID: Int?
    @FocusState private var focused: Bool

    init(prefill: String) {
        _text = State(initialValue: prefill)
    }

    private var group: LinkGroup? { model.inbox.group(groupID) }

    private var detected: URL? { LinkText.firstURL(in: text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste any link", text: $text, axis: .vertical)
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
                    let people = model.inbox.recipients(in: group).map(\.name)
                    if !people.isEmpty { Text("Goes to \(LinkFormat.names(people)).") }
                }
                if model.inbox.groups.count > 1 {
                    Section {
                        Picker("To", selection: $groupID) {
                            ForEach(model.inbox.groups) { group in
                                Text(model.inbox.destinationTitle(of: group)).tag(Int?.some(group.id))
                            }
                        }
                        .accessibilityIdentifier("addLink.chat")
                    }
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
                                try await model.send(text, note: note, groupID: groupID)
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
        .onAppear {
            if groupID == nil { groupID = (model.inbox.group(model.chat) ?? model.inbox.preferredGroup)?.id }
            if text.isEmpty { focused = true }
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
                    Text("Their links, seen marks and reactions move to your account, and you take that name.")
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
