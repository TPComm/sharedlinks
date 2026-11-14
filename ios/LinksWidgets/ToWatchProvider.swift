import AppIntents
import LinksKit
import OSLog
import UIKit
import WidgetKit

private let log = Logger(subsystem: "links.widgets", category: "timeline")

enum WidgetFeed: String, AppEnum {
    case toWatch, sent

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Feed"
    static let caseDisplayRepresentations: [WidgetFeed: DisplayRepresentation] = [
        .toWatch: DisplayRepresentation(title: "To Watch", subtitle: "Links you haven't watched yet"),
        .sent: DisplayRepresentation(title: "Sent", subtitle: "What you sent, and who's seen it"),
    ]
}

struct LinksWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Links"
    static let description = IntentDescription("Links you haven't watched, or read receipts for links you sent.")

    @Parameter(title: "Show", default: .toWatch)
    var feed: WidgetFeed

    /// Empty is every chat.
    @Parameter(title: "Chat", description: "Only links in this chat. Leave it empty for all chats.")
    var chat: ChatEntity?

    init() {}
    init(feed: WidgetFeed, chat: ChatEntity? = nil) {
        self.feed = feed
        self.chat = chat
    }
}

struct WidgetItem: Identifiable {
    let id: Int
    let title: String
    let platform: Platform
    let from: String
    let ago: String
    /// "Seen by Sam" / "Not seen yet" for the Sent feed.
    let receipt: String?
    let seenByOthers: Bool
    let image: UIImage?
}

struct LinksEntry: TimelineEntry {
    enum Content {
        case signedOut
        case links(count: Int, items: [WidgetItem])
    }

    let date: Date
    let feed: WidgetFeed
    /// The chat's name, for a widget set to one chat.
    var chat: String? = nil
    let content: Content
}

struct LinksProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LinksEntry {
        .sample(feed: .toWatch)
    }

    func snapshot(for configuration: LinksWidgetConfiguration, in context: Context) async -> LinksEntry {
        if context.isPreview && InboxSnapshot.load() == nil { return .sample(feed: configuration.feed) }
        return await entry(for: configuration.feed, chat: configuration.chat?.id, family: context.family, fetch: false)
    }

    func timeline(for configuration: LinksWidgetConfiguration, in context: Context) async -> Timeline<LinksEntry> {
        let entry = await entry(for: configuration.feed, chat: configuration.chat?.id, family: context.family, fetch: true)
        if case .links(let count, let items) = entry.content {
            log.debug("timeline \(context.family.debugDescription, privacy: .public): \(count) links, showing \(items.map(\.id), privacy: .public)")
        }
        // The app and Share Extension reload widgets when something changes; this is the fallback.
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(for feed: WidgetFeed, chat chatID: Int?, family: WidgetFamily, fetch: Bool) async -> LinksEntry {
        guard let token = SessionStore.token else { return LinksEntry(date: .now, feed: feed, content: .signedOut) }
        let client = APIClient(token: token)
        var state = InboxSnapshot.load()
        if fetch {
            do {
                let fresh = try await client.state()
                InboxSnapshot.save(fresh)
                state = fresh
            } catch APIError.signedOut {
                return LinksEntry(date: .now, feed: feed, content: .signedOut)
            } catch {
                // Offline: draw what we had.
            }
        }
        guard let state else { return LinksEntry(date: .now, feed: feed, content: .links(count: 0, items: [])) }

        // A chat I've since left: show every chat rather than an empty widget.
        let chat = state.group(chatID)
        let links = state.links(for: feed == .sent ? .sent : .toWatch, in: chat?.id)
        let limit = switch family {
        case .systemLarge, .systemExtraLarge: 5
        case .systemMedium: 2
        default: 1
        }
        var items: [WidgetItem] = []
        for link in links.prefix(limit) {
            let data = fetch ? await ThumbnailStore.shared.data(for: link, client: client) : ThumbnailStore.cached(link)
            let others = state.seenByOthers(link)
            items.append(WidgetItem(
                id: link.id,
                title: link.displayTitle,
                platform: link.platform,
                from: state.isMine(link) ? "You" : state.name(of: link.addedBy),
                ago: LinkFormat.ago(link.addedAt),
                receipt: feed == .sent ? (others.isEmpty ? "Not seen yet" : "Seen by \(LinkFormat.names(others))") : nil,
                seenByOthers: !others.isEmpty,
                image: data.flatMap(UIImage.init(data:))))
        }
        return LinksEntry(date: .now, feed: feed, chat: chat.map(state.title(of:)),
                          content: .links(count: links.count, items: items))
    }
}

extension LinksEntry {
    static func sample(feed: WidgetFeed) -> LinksEntry {
        let titles = ["The dog that learned to skateboard", "Trying every pasta shape", "This trick shot took 400 tries",
                      "Tiny kitchen, huge flavor", "Wait for the ending"]
        let platforms: [Platform] = [.tiktok, .instagram, .youtube, .tiktok, .instagram]
        let items = titles.enumerated().map { i, title in
            WidgetItem(id: i, title: title, platform: platforms[i], from: ["Sam", "Alex"][i % 2], ago: "\(i + 1)h",
                       receipt: feed == .sent ? (i == 0 ? "Seen by Sam" : "Not seen yet") : nil,
                       seenByOthers: i == 0, image: nil)
        }
        return LinksEntry(date: .now, feed: feed, content: .links(count: 3, items: items))
    }
}

/// The checkmark button on widget rows. Runs in the widget's process, no app launch.
struct MarkWatchedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark as Watched"
    static let isDiscoverable = false

    @Parameter(title: "Link")
    var linkID: Int

    init() {}
    init(linkID: Int) { self.linkID = linkID }

    func perform() async throws -> some IntentResult {
        do {
            let link = try await APIClient().setSeen(linkID, true)
            InboxSnapshot.update { state in
                if let i = state.links.firstIndex(where: { $0.id == link.id }) { state.links[i] = link }
            }
        } catch {
            // Offline or signed out: leave it unwatched rather than pretend. The row stays, so the
            // tap visibly didn't take and can be retried.
        }
        // WidgetKit reloads after an interaction anyway, but an explicit request also makes the
        // Home Screen redraw right away (in testing, the interaction reload alone could lag a step).
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
