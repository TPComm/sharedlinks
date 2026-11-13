import LinksKit
import SwiftUI

enum InboxTab: Hashable {
    case toWatch, watched, sent, search
}

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("To Watch", systemImage: "play.rectangle.on.rectangle", value: .toWatch) {
                LinkListScreen(filter: .toWatch)
            }
            .badge(model.inbox.toWatch.count)

            Tab("Watched", systemImage: "checkmark.circle", value: .watched) {
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
        .sheet(isPresented: $model.showClaimSheet) {
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
        NavigationStack {
            LinkList(filter: filter, query: query)
                .navigationTitle(filter.title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { AccountMenu() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.addPrefill = ""
                            model.showAddSheet = true
                        } label: {
                            Label("New Link", systemImage: "plus")
                        }
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
        let links = model.inbox.links(for: filter, matching: query)
        List(links) { link in
            LinkRow(link: link)
        }
        .listStyle(.plain)
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
        } else if model.inbox.links.isEmpty {
            ContentUnavailableView {
                Label("No Links Yet", systemImage: "film.stack")
            } description: {
                Text("Share a reel or TikTok to Links from any app, or tap + to paste one.")
            } actions: {
                Button("New Link") { model.showAddSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch filter {
            case .toWatch:
                ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle",
                                       description: Text("You've watched everything you were sent."))
            case .watched:
                ContentUnavailableView("Nothing Watched Yet", systemImage: "popcorn",
                                       description: Text("Links you've watched show up here."))
            case .sent:
                ContentUnavailableView("Nothing Sent Yet", systemImage: "paperplane",
                                       description: Text("Links you share show up here, with who's seen them."))
            case .all:
                ContentUnavailableView("No Links Yet", systemImage: "film.stack")
            }
        }
    }
}
