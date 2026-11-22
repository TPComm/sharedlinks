import LinksKit
import SwiftUI

struct ActivityScreen: View {
    @Environment(AppModel.self) private var model
    @State private var items: [ActivityItem] = []
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var commentLinkID: Int?

    var body: some View {
        NavigationStack(path: Binding(get: { model.paths[.activity] ?? [] }, set: { model.paths[.activity] = $0 })) {
            List {
                ForEach(items) { item in
                    if let link = model.inbox.links.first(where: { $0.id == item.linkID }) {
                        Button {
                            commentLinkID = item.kind == .comment ? link.id : nil
                            model.showPage(link, on: .activity)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(user: model.inbox.user(item.person), size: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.inbox.name(of: item.person)).font(.headline)
                                    Text(action(item)).font(.subheadline).lineLimit(2)
                                    Text(link.title ?? link.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(item.at, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if model.hasUnreadComment(item) {
                                    Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.tint)
                                        .accessibilityLabel("Unread comment")
                                }
                                ThumbnailView(link: link).frame(width: 48, height: 56)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("activity.\(item.kind.rawValue).\(item.linkID)")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load(more: false) } }
                }
                if hasMore {
                    Button("Load More") { Task { await load(more: true) } }
                        .disabled(loading)
                }
                if loading { ProgressView() }
            }
            .listStyle(.plain)
            .navigationTitle("Activity")
            .toolbar { ToolbarItem(placement: .topBarLeading) { ProfileButton() } }
            .navigationDestination(for: Int.self) { LinkDetailView(linkID: $0, showComments: commentLinkID == $0) }
            .overlay {
                if !loading && error == nil && !items.contains(where: { item in model.inbox.links.contains { $0.id == item.linkID } }) {
                    ContentUnavailableView("No activity yet", systemImage: "bell",
                                           description: Text("Comments, reactions and watched links from your chats show up here."))
                }
            }
            .refreshable {
                await model.refresh()
                await load(more: false)
            }
            .task {
                if model.tab == .activity { await load(more: false) }
            }
            .onChange(of: model.tab) { _, tab in
                if tab == .activity { Task { await load(more: false) } }
            }
            .onChange(of: model.inboxRefresh) { _, _ in
                if model.tab == .activity { Task { await load(more: false) } }
            }
        }
    }

    private func action(_ item: ActivityItem) -> String {
        switch item.kind {
        case .comment: "commented: \(item.snippet ?? "")"
        case .reaction: "reacted \(item.emoji ?? "")"
        case .watched: "watched"
        }
    }

    private func load(more: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await model.client.activity(before: more ? items.last?.at : nil)
            try Task.checkCancellation()
            let existing = more ? Set(items.map(\.id)) : []
            items = (more ? items : []) + page.items.filter { !existing.contains($0.id) }
            hasMore = page.hasMore
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
