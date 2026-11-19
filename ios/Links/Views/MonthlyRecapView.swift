import SwiftUI
import LinksKit

struct MonthlyRecapSection: View {
    @Environment(AppModel.self) private var model
    let group: LinkGroup
    let openLink: (SharedLink) -> Void
    @State private var showing = false
    @State private var selected: SharedLink?

    var body: some View {
        let recap = model.inbox.monthlyRecap(in: group.id)
        Section {
            Button { showing = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(recap.month.start.formatted(.dateTime.month(.wide))) in Links", systemImage: "sparkles")
                        .font(.headline)
                    Text("\(recap.linkCount) \(recap.linkCount == 1 ? "link" : "links") this month")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
            }
            .accessibilityIdentifier("monthlyRecap.open")
        }
        .sheet(isPresented: $showing, onDismiss: {
            if let link = selected { selected = nil; openLink(link) }
        }) {
            MonthlyRecapSheet(group: group, recap: recap) { link in
                selected = link
                showing = false
            }
        }
    }
}

private struct MonthlyRecapSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: LinkGroup
    let recap: MonthlyRecap
    let openLink: (SharedLink) -> Void
    @State private var shareImage: Image?

    var body: some View {
        NavigationStack {
            ScrollView {
                MonthlyRecapCard(inbox: model.inbox, group: group, recap: recap, openLink: openLink)
                    .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Month in Links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    if recap.linkCount > 0, let shareImage {
                        ShareLink(item: shareImage, preview: SharePreview("Month in Links", image: shareImage)) {
                            Label("Share recap", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("monthlyRecap.share")
                    }
                }
            }
            .task {
                if let link = recap.mostLoved?.link {
                    _ = await ThumbnailCache.image(for: link, client: model.client)
                }
                let renderer = ImageRenderer(content:
                    MonthlyRecapCard(inbox: model.inbox, group: group, recap: recap, exporting: true, openLink: { _ in })
                        .padding(24).frame(width: 390)
                        .background(Color(.systemGroupedBackground))
                        .environment(\.dynamicTypeSize, .large)
                        .environment(\.colorScheme, .light))
                renderer.scale = 2
                if let image = renderer.uiImage { shareImage = Image(uiImage: image) }
            }
        }
    }
}

private struct MonthlyRecapCard: View {
    let inbox: InboxState
    let group: LinkGroup
    let recap: MonthlyRecap
    var exporting = false
    let openLink: (SharedLink) -> Void

    private var month: String { recap.month.start.formatted(.dateTime.month(.wide)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(month) in Links").font(.title.bold())
                Text(inbox.title(of: group)).font(.subheadline).foregroundStyle(.secondary)
            }
            if recap.linkCount == 0 {
                Image(systemName: "moon.stars").font(.largeTitle).foregroundStyle(.indigo)
                Text("Quiet month").font(.title2.bold())
                Text("Share something to start \(month)’s recap.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recap.linkCount.formatted()).font(.system(.largeTitle, design: .rounded, weight: .black))
                    Text("links shared").font(.title2.bold())
                    Text("From \(recap.sharerCount) \(recap.sharerCount == 1 ? "sharer" : "sharers") this month")
                        .foregroundStyle(.secondary)
                }
                if let loved = recap.mostLoved {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        heading("Most loved", icon: "heart.fill")
                        Button { openLink(loved.link) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Group {
                                    if exporting {
                                        ThumbnailImage(platform: loved.link.platform,
                                                       image: ThumbnailCache.cachedImage(for: loved.link), cornerRadius: 10)
                                    } else {
                                        ThumbnailView(link: loved.link)
                                    }
                                }
                                .frame(height: 150).clipped().accessibilityHidden(true)
                                Text(loved.link.displayTitle).font(.title3.bold()).foregroundStyle(.primary)
                                if let sender = named(loved.link.addedBy) {
                                    Text("Shared by \(sender)").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text(loved.emojiCounts.keys.sorted().map { "\($0) \(loved.emojiCounts[$0]!)" }.joined(separator: "   "))
                                    .font(.headline).foregroundStyle(.primary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the link page without changing Seen status")
                        .accessibilityIdentifier("monthlyRecap.loved")
                    }
                }
                if let top = recap.topSharer, let name = named(top.member) {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        heading("Top sharer", icon: "paperplane.fill")
                        Text(name).font(.title2.bold())
                        Text("\(top.count) \(top.count == 1 ? "link" : "links") shared").foregroundStyle(.secondary)
                    }
                }
                if let watcher = recap.fastestWatcher, let name = named(watcher.member) {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        heading("Fastest watcher", icon: "bolt.fill")
                        Text(name).font(.title2.bold())
                        Text("Watches in ~\(duration(watcher.medianInterval)) on average")
                        Text("Median of \(watcher.receiptCount) Seen receipts. Marked Seen, not measured watch time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Based on links you can see, shared this calendar month. Reactions and Seen marks can change.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private func heading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(.indigo)
    }

    private func named(_ id: String) -> String? {
        guard group.members.contains(id), id != LinkUser.deletedID, inbox.user(id) != nil, !inbox.isBlocked(id) else { return nil }
        return id == inbox.me ? "You" : inbox.name(of: id)
    }

    private func duration(_ interval: TimeInterval) -> String {
        if interval < 60 { return "\(max(1, Int(interval.rounded()))) sec" }
        if interval < 3600 { return "\(Int((interval / 60).rounded())) min" }
        if interval < 86400 { return "\(Int((interval / 3600).rounded())) hr" }
        return "\(Int((interval / 86400).rounded())) days"
    }
}
