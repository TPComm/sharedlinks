import LinksKit
import SwiftUI

enum InboxTab: String, Hashable, Codable {
    case toWatch, watched, sent, search

    /// The tab that shows a filter's list.
    init(_ filter: InboxFilter) {
        switch filter {
        case .toWatch: self = .toWatch
        case .watched: self = .watched
        case .sent: self = .sent
        case .all: self = .search
        }
    }
}

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Queue", systemImage: "tray.full", value: .toWatch) {
                LinkListScreen(filter: .toWatch)
            }
            .badge(model.inbox.toWatch.count)

            Tab("Seen", systemImage: "checkmark.circle", value: .watched) {
                LinkListScreen(filter: .watched)
            }

            Tab("Sent", systemImage: "paperplane", value: .sent) {
                LinkListScreen(filter: .sent)
            }

            Tab(value: .search, role: .search) {
                LinkListScreen(filter: .all, query: query)
                    .searchable(text: $query, prompt: "Titles, people, notes")
            }
        }
        .sheet(isPresented: $model.showAddSheet) {
            AddLinkSheet(prefill: model.addPrefill)
        }
        .sheet(item: $model.chatSheet) { ChatSheetView(sheet: $0) }
        .fullScreenCover(item: $model.swipeQueue) { SwipeQueueView(queue: $0) }
        // The tour waits for the claim sheet to be gone, not just going.
        .sheet(isPresented: $model.showClaimSheet, onDismiss: { model.showTourIfNeeded() }) {
            ClaimSheet()
        }
        // Drop a link from Safari (iPad, or iPhone with drag and drop) anywhere to send it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.add(url.absoluteString) }
            return true
        }
    }
}

struct LinkListScreen: View {
    @Environment(AppModel.self) private var model
    let filter: InboxFilter
    var query: String = ""

    var body: some View {
        let tab = InboxTab(filter)
        NavigationStack(path: Binding(get: { model.paths[tab] ?? [] }, set: { model.paths[tab] = $0 })) {
            LinkList(filter: filter, query: query)
                .navigationTitle(filter.title)
                .navigationDestination(for: Int.self) { LinkDetailView(linkID: $0) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { ProfileButton() }
                    if filter == .toWatch, !model.inbox.links(for: .toWatch, in: model.chat).isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                model.swipeQueue = SwipeQueue(model.inbox, in: model.chat)
                            } label: {
                                Label("Swipe Through", systemImage: "rectangle.stack")
                            }
                            .accessibilityIdentifier("swipeQueue.open")
                        }
                    }
                    // Servers from before chats have none to pick from.
                    if !model.inbox.groups.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) { ChatPicker() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.addPrefill = ""
                            model.showAddSheet = true
                        } label: {
                            Label("New Link", systemImage: "plus")
                        }
                        .accessibilityIdentifier("newLink")
                    }
                }
        }
    }
}

struct LinkList: View {
    @Environment(AppModel.self) private var model
    let filter: InboxFilter
    let query: String

    var body: some View {
        if filter == .watched && query.isEmpty {
            // Eligibility can change with time even when the inbox is unchanged and no card exists yet.
            TimelineView(.everyMinute) { _ in
                list(on: ThrowbackCard.now)
            }
        } else {
            list(on: .now)
        }
    }

    private func list(on date: Date) -> some View {
        let links = model.inbox.links(for: filter, in: model.chat, matching: query)
        return List {
            if filter == .watched && query.isEmpty,
               !model.inbox.throwbacks(in: model.chat, now: date, minimumAge: ThrowbackCard.minimumAge).isEmpty {
                ThrowbackCard(date: date)
                    .id(model.chat)
                    .listRowSeparator(.hidden)
            }
            ForEach(links) { link in
                LinkRow(link: link, tab: InboxTab(filter))
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("links.\(filter.rawValue)")
        .environment(\.gestureTipsLinkID, filter == .toWatch ? links.first?.id : nil)
        .animation(.default, value: links.map(\.id))
        .refreshable { await model.refresh() }
        .overlay {
            if links.isEmpty { emptyState }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isOffline {
                Label("Offline. Showing what was here last.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if let group = model.inbox.group(model.chat), model.inbox.links(in: group.id).isEmpty {
            ContentUnavailableView {
                Label("Nothing in \(model.inbox.title(of: group)) Yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Links sent to this chat show up here.")
            } actions: {
                Button("New Link") { model.showAddSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.inbox.links.isEmpty {
            ContentUnavailableView {
                Label("No Links Yet", systemImage: "film.stack")
            } description: {
                Text("Share any link to Links from another app, or tap + to paste one.")
            } actions: {
                Button("New Link") { model.showAddSheet = true }
                    .buttonStyle(.borderedProminent)
                if !Onboarding.shared.hasOpenedShareExtension {
                    Button("Add Links to Your Share Sheet") { model.startTour(at: .shareSheet) }
                }
            }
        } else {
            switch filter {
            case .toWatch:
                ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle",
                                       description: Text("You've seen everything you were sent."))
            case .watched:
                ContentUnavailableView("Nothing Seen Yet", systemImage: "popcorn",
                                       description: Text("Links you've seen show up here."))
            case .sent:
                ContentUnavailableView("Nothing Sent Yet", systemImage: "paperplane",
                                       description: Text("Links you share show up here, with who's seen them."))
            case .all:
                ContentUnavailableView("No Links Yet", systemImage: "film.stack")
            }
        }
    }
}
