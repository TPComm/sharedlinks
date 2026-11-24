import LinksKit
import SwiftUI

struct ActivityScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [ActivityItem] = []
    @State private var feed = ActivityFeed()
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(feed.items) { item in
                    if let link = model.inbox.links.first(where: { $0.id == item.linkID }) {
                        Button {
                            model.markActivityRead(item)
                            path.append(item)
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
                        .accessibilityIdentifier("activity.\(item.kind.rawValue).\(item.linkID)\(item.commentID.map { ".\($0)" } ?? "")")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load(.newest) } }
                }
                if feed.hasMore {
                    Button("Load More") { Task { await load(.older) } }
                        .disabled(loading)
                }
                if loading { ProgressView() }
            }
            .listStyle(.plain)
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ActivityItem.self) { item in
                LinkDetailView(linkID: item.linkID, destination: item.kind == .comment
                               ? .comment(item.commentID) : item.kind == .seen ? .seen : .reactions)
            }
            .overlay {
                if !loading && error == nil && !feed.items.contains(where: { item in model.inbox.links.contains { $0.id == item.linkID } }) {
                    ContentUnavailableView("No activity yet", systemImage: "bell",
                                           description: Text("Comments, reactions and seen marks from your chats show up here."))
                }
            }
            .refreshable {
                await model.refresh()
                await load(.reset)
            }
            .task { await load(.reset) }
            .onChange(of: model.inboxRefresh) { _, _ in
                Task { await load(.newest) }
            }
        }
    }

    private func action(_ item: ActivityItem) -> String {
        switch item.kind {
        case .comment: "commented: \(item.snippet ?? "")"
        case .reaction: "reacted \(item.emoji ?? "")"
        case .seen: "saw your link"
        }
    }

    private func load(_ update: ActivityFeed.Update) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await model.client.activity(cursor: update == .older ? feed.next : nil)
            try Task.checkCancellation()
            feed.apply(page, update: update)
            if update == .reset, let newest = page.items.map(\.at).max() {
                model.markActivityViewed(through: newest)
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
