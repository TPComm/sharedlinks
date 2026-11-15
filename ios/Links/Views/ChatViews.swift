import LinksKit
import SwiftUI

/// The sheets the chat picker opens.
enum ChatSheet: Identifiable, Hashable {
    case start
    case rename(LinkGroup)
    case addPeople(LinkGroup)

    var id: String {
        switch self {
        case .start: "start"
        case .rename(let group): "rename-\(group.id)"
        case .addPeople(let group): "add-\(group.id)"
        }
    }
}

/// Which chat the lists show, "All Chats" first, and what you can do with the one showing.
/// Lives on every tab rather than a separate chat list (#12).
struct ChatPicker: View {
    @Environment(AppModel.self) private var model
    @State private var leaving: LinkGroup?

    private var inbox: InboxState { model.inbox }
    private var selected: LinkGroup? { inbox.group(model.chat) }

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Chat", selection: $model.chat) {
                Label("All Chats", systemImage: "tray.full").tag(Int?.none)
                ForEach(inbox.groups) { group in
                    Text(inbox.title(of: group)).tag(Int?.some(group.id))
                }
            }
            .pickerStyle(.inline)
            if let group = selected {
                Section(inbox.title(of: group)) {
                    Button("Rename…", systemImage: "pencil") { model.chatSheet = .rename(group) }
                    if !inbox.addable(to: group).isEmpty {
                        Button("Add People…", systemImage: "person.badge.plus") { model.chatSheet = .addPeople(group) }
                    }
                    Button("Leave Chat", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        leaving = group
                    }
                }
            }
            Section {
                Button("New Chat…", systemImage: "square.and.pencil") { model.chatSheet = .start }
                    .disabled(inbox.otherPeople.isEmpty)
            }
        } label: {
            Label(selected.map(inbox.title(of:)) ?? "All Chats", systemImage: "bubble.left.and.bubble.right")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .accessibilityIdentifier("chatPicker")
        .confirmationDialog(leaving.map { "Leave \(inbox.title(of: $0))?" } ?? "", isPresented: Binding(
            get: { leaving != nil }, set: { if !$0 { leaving = nil } }), titleVisibility: .visible, presenting: leaving
        ) { group in
            Button("Leave Chat", role: .destructive) { Task { await model.leaveChat(group) } }
        } message: { group in
            if group.isDefault {
                Text("You stop getting links sent to everyone. The links you sent stay for everyone else.")
            } else if group.members.allSatisfy({ $0 == inbox.me }) {
                // The server deletes a chat nobody is in, with its links (deleteEmptyGroups).
                Text("You’re the last one in it, so the chat and its links are deleted.")
            } else {
                Text("Its links leave your lists. The links you sent stay in the chat for everyone else.")
            }
        }
    }
}

/// Start a chat, rename one, or add people to one. Nobody can be removed: people leave by themselves.
struct ChatSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sheet: ChatSheet
    @State private var name = ""
    @State private var picked: Set<String> = []
    @State private var saving = false
    @State private var failure: String?

    private var inbox: InboxState { model.inbox }

    /// The people to pick from: everyone I share a chat with for a new chat, those not in it yet otherwise.
    private var people: [LinkUser] {
        switch sheet {
        case .start: inbox.otherPeople.filter { !inbox.isBlocked($0.id) }
        case .rename: []
        case .addPeople(let group): inbox.addable(to: group)
        }
    }

    private var title: String {
        switch sheet {
        case .start: "New Chat"
        case .rename: "Rename Chat"
        case .addPeople: "Add People"
        }
    }

    private var canSave: Bool {
        switch sheet {
        case .start, .addPeople: !picked.isEmpty
        case .rename: true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if case .addPeople = sheet {} else {
                    Section {
                        TextField(namePrompt, text: $name)
                            .accessibilityIdentifier("chat.name")
                    } footer: {
                        Text("Leave it empty to name the chat after the people in it.")
                    }
                }
                if !people.isEmpty {
                    Section {
                        ForEach(people) { person in
                            Button {
                                if picked.contains(person.id) { picked.remove(person.id) } else { picked.insert(person.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(user: person, size: 28)
                                    Text(person.name).foregroundStyle(.primary)
                                    Spacer()
                                    if picked.contains(person.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityIdentifier("chat.person.\(person.name)")
                            .accessibilityAddTraits(picked.contains(person.id) ? .isSelected : [])
                        }
                    } header: {
                        Text(sheet == .start ? "With" : "Add")
                    } footer: {
                        Text(sheet == .start
                             ? "Anyone in the chat can add people and send links to it. Everyone can leave."
                             : "They see the chat's links, including the ones sent before they joined.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sheet == .start ? "Start" : "Done") { save() }
                        .disabled(!canSave || saving)
                        .accessibilityIdentifier("chat.save")
                }
            }
            .failureAlert($failure)
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if case .rename(let group) = sheet { name = group.name }
        }
    }

    private var namePrompt: String {
        if case .rename(let group) = sheet, group.name.isEmpty { return inbox.title(of: group) }
        return "Chat name (optional)"
    }

    private func save() {
        saving = true
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Server order: oldest first is fine for picking; keep the list's order.
        let members = people.map(\.id).filter(picked.contains)
        Task {
            do {
                switch sheet {
                case .start: try await model.startChat(name: name, members: members)
                case .rename(let group): try await model.renameChat(group, to: name)
                case .addPeople(let group): try await model.addPeople(members, to: group)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            saving = false
        }
    }
}
