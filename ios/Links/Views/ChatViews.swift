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
    @State private var showingChats = false
    @State private var infoGroup: LinkGroup?

    private var inbox: InboxState { model.inbox }
    private var selected: LinkGroup? { inbox.group(model.chat) }

    var body: some View {
        TimelineView(.everyMinute) { context in
            picker(at: context.date)
        }
    }

    private func picker(at now: Date) -> some View {
        @Bindable var model = model
        return Menu {
            Picker("Chat", selection: $model.chat) {
                Label("All Chats", systemImage: "tray.full").tag(Int?.none)
                ForEach(inbox.groups) { group in
                    Label(inbox.destinationTitle(of: group), systemImage: group.isMuted(at: now) ? "bell.slash" : "bubble.left.and.bubble.right")
                        .tag(Int?.some(group.id))
                }
            }
            .pickerStyle(.inline)
            if let group = selected {
                Section(inbox.destinationTitle(of: group)) {
                    Button("Chat Info", systemImage: "info.circle") { infoGroup = group }
                    if !group.isDirect {
                        Button("Rename…", systemImage: "pencil") { model.chatSheet = .rename(group) }
                        if !inbox.addable(to: group).isEmpty {
                            Button("Add People…", systemImage: "person.badge.plus") { model.chatSheet = .addPeople(group) }
                        }
                    }
                    if inbox.canLeave(group) {
                        Button("Leave Chat", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            leaving = group
                        }
                    }
                }
            }
            Section {
                Button("Chats…", systemImage: "bubble.left.and.bubble.right") { showingChats = true }
                Button("New Chat…", systemImage: "square.and.pencil") { model.chatSheet = .start }
                    .disabled(inbox.otherPeople.isEmpty)
            }
        } label: {
            Label(selected.map(inbox.destinationTitle(of:)) ?? "All Chats",
                  systemImage: selected?.isMuted(at: now) == true ? "bell.slash" : "bubble.left.and.bubble.right")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .accessibilityIdentifier("chatPicker")
        .sheet(isPresented: $showingChats) { ChatListView() }
        .sheet(item: $infoGroup) { group in
            NavigationStack {
                ChatInfoView(groupID: group.id) { link in
                    infoGroup = nil
                    model.showPage(link)
                }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { infoGroup = nil } } }
            }
        }
        .confirmationDialog(leaving.map { "Leave \(inbox.destinationTitle(of: $0))?" } ?? "", isPresented: Binding(
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

/// A compact list alongside the existing picker, with per-chat notification shortcuts.
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var muting: LinkGroup?
    @State private var saving: Set<Int> = []
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                List(model.inbox.groups) { group in
                    NavigationLink(value: group.id) {
                        HStack {
                            Text(model.inbox.destinationTitle(of: group))
                            Spacer()
                            if group.isMuted(at: context.date) {
                                Image(systemName: "bell.slash")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Muted")
                                    .accessibilityIdentifier("chat.muted.\(group.id)")
                            }
                        }
                    }
                    .accessibilityIdentifier("chat.row.\(group.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if group.muted != nil {
                            Button(group.isMuted(at: context.date) ? "Unmute" : "Mute",
                                   systemImage: group.isMuted(at: context.date) ? "bell" : "bell.slash") {
                                if group.isMuted() { save(group, muted: false) } else { muting = group }
                            }
                            .tint(.indigo)
                            .disabled(saving.contains(group.id))
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: Int.self) { groupID in
                ChatInfoView(groupID: groupID) { link in
                    dismiss()
                    model.showPage(link)
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Mute Notifications", isPresented: Binding(
                get: { muting != nil }, set: { if !$0 { muting = nil } }),
                titleVisibility: .visible, presenting: muting
            ) { group in
                ChatMuteOptions { duration in save(group, muted: true, until: duration.endDate()) }
            } message: { _ in
                Text("Until Tomorrow ends at 9 AM. Muted chats still count toward your badge.")
            }
            .failureAlert($failure)
        }
    }

    private func save(_ group: LinkGroup, muted: Bool, until: Date? = nil) {
        saving.insert(group.id)
        Task {
            do { try await model.setChatMuted(group, muted: muted, until: until) }
            catch { failure = error.localizedDescription }
            saving.remove(group.id)
        }
    }
}

struct ChatInfoView: View {
    @Environment(AppModel.self) private var model
    let groupID: Int
    let openLink: (SharedLink) -> Void
    @State private var choosingDuration = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            Form {
                if let group = model.inbox.group(groupID) {
                    Section {
                        Text(model.inbox.destinationTitle(of: group)).font(.headline)
                    }
                    TasteMatchSection(group: group, openLink: openLink)
                    if group.muted != nil {
                        Section {
                            Toggle(isOn: Binding(get: { group.isMuted(at: context.date) }, set: { muted in
                                if muted { choosingDuration = true } else { save(group, muted: false) }
                            })) {
                                Label("Mute Notifications", systemImage: "bell.slash")
                            }
                            .disabled(saving)
                            .accessibilityIdentifier("chat.mute")
                            if group.isMuted(at: context.date) {
                                if let until = group.mutedUntil {
                                    LabeledContent("Muted Until") {
                                        Text(until, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    }
                                    .accessibilityIdentifier("chat.mutedUntil")
                                } else {
                                    Text("Muted until you turn notifications back on.").foregroundStyle(.secondary)
                                }
                                Button("Change Duration…") { choosingDuration = true }.disabled(saving)
                            }
                        } header: {
                            Text("Notifications")
                        } footer: {
                            Text("Only your notifications for this chat are muted. Links still appear and count toward your badge.")
                        }
                        .confirmationDialog("Mute Notifications", isPresented: $choosingDuration, titleVisibility: .visible) {
                            ChatMuteOptions { duration in save(group, muted: true, until: duration.endDate()) }
                        } message: {
                            Text("Until Tomorrow ends at 9 AM.")
                        }
                    }
                    Section("People") {
                        ForEach(group.members, id: \.self) { person in
                            Text(model.inbox.name(of: person))
                        }
                    }
                } else {
                    Text("You’re no longer in this chat.")
                }
            }
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Chat Info")
        .navigationBarTitleDisplayMode(.inline)
        .failureAlert($failure)
    }

    private func save(_ group: LinkGroup, muted: Bool, until: Date? = nil) {
        saving = true
        Task {
            do { try await model.setChatMuted(group, muted: muted, until: until) }
            catch { failure = error.localizedDescription }
            saving = false
        }
    }
}

private struct TasteMatchSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let group: LinkGroup
    let openLink: (SharedLink) -> Void

    var body: some View {
        let matches = model.inbox.tasteMatches(in: group.id)
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: matches.isEmpty ? "heart" : "heart.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .accessibilityHidden(true)
                if matches.isEmpty {
                    Text("No shared loves yet")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("tasteMatch.empty")
                    Text(group.members.count < 2
                         ? "Add someone to this chat to find your shared favorites."
                         : "When everyone reacts with ❤️, 😂 or 🔥 to the same link, you’ll find it here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.inbox.tasteMatchSummary(in: group.id, count: matches.count))
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("tasteMatch.summary")
                    Text("Your latest shared favorites.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)

            ForEach(matches.prefix(3)) { link in
                Button {
                    openLink(link)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        if !typeSize.isAccessibilitySize {
                            ThumbnailView(link: link)
                                .frame(width: 52, height: 64)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(link.displayTitle)
                                .font(.headline)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            Text(link.sourceName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the link page without changing seen status")
                .accessibilityIdentifier("tasteMatch.link.\(link.id)")
            }
        } header: {
            Text("Taste Match")
        } footer: {
            if !matches.isEmpty {
                Text("❤️, 😂 and 🔥 count as a love. Based on links you can see, with a reaction from everyone currently in this chat.")
                    .accessibilityLabel("Heart, laughing and fire reactions count as a love. Based on links you can see, with a reaction from everyone currently in this chat.")
            }
        }
    }
}

private struct ChatMuteOptions: View {
    let choose: (ChatMuteDuration) -> Void

    var body: some View {
        ForEach(ChatMuteDuration.allCases, id: \.self) { duration in
            Button(duration.title) { choose(duration) }
        }
        Button("Cancel", role: .cancel) {}
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
