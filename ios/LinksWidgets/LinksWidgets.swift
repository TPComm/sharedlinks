import AppIntents
import LinksKit
import SwiftUI
import WidgetKit

@main
struct LinksWidgetBundle: WidgetBundle {
    var body: some Widget {
        LinksWidget()
    }
}

struct LinksWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LinksWidget", intent: LinksWidgetConfiguration.self, provider: LinksProvider()) { entry in
            LinksWidgetView(entry: entry)
        }
        .configurationDisplayName("Links")
        .description("What's waiting for you to see, or who's seen what you sent.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct LinksWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LinksEntry

    var body: some View {
        switch entry.content {
        case .signedOut:
            SignedOutView()
                .containerBackground(for: .widget) { BrandBackground() }
        case .links(let count, let items):
            switch family {
            case .accessoryCircular: CircularView(count: count, feed: entry.feed)
            case .accessoryRectangular: RectangularView(count: count, items: items, feed: entry.feed)
            case .accessoryInline: InlineView(count: count, feed: entry.feed)
            case .systemSmall: SmallView(count: count, item: items.first, feed: entry.feed)
            default: ListView(count: count, items: items, feed: entry.feed, chat: entry.chat)
            }
        }
    }
}

// MARK: Home Screen

private struct SmallView: View {
    let count: Int
    let item: WidgetItem?
    let feed: WidgetFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(feed == .toWatch ? "\(count)" : "Sent")
                    .font(.system(size: feed == .toWatch ? 40 : 22, weight: .bold, design: .rounded))
                    .contentTransition(.identity)
                Spacer()
                Image(systemName: feed == .toWatch ? "play.fill" : "paperplane.fill")
                    .font(.subheadline.weight(.semibold))
            }
            if feed == .toWatch {
                Text("to see").font(.subheadline.weight(.semibold)).opacity(0.85)
            }
            Spacer(minLength: 0)
            if let item {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                Text(item.receipt ?? "from \(item.from)")
                    .font(.caption)
                    .lineLimit(1)
                    .opacity(0.85)
            } else {
                Text(feed == .toWatch ? "All caught up" : "Nothing sent yet")
                    .font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .containerBackground(for: .widget) {
            ZStack {
                if let item {
                    ThumbnailImage(platform: item.platform, image: item.image, cornerRadius: 0)
                    LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.1), .black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    BrandBackground()
                }
            }
        }
        .widgetURL(item.map { DeepLink.open(linkID: $0.id).url } ?? DeepLink.inbox.url)
    }
}

private struct ListView: View {
    @Environment(\.widgetFamily) private var family
    let count: Int
    let items: [WidgetItem]
    let feed: WidgetFeed
    var chat: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(feed == .toWatch ? "To Watch" : "Sent", systemImage: feed == .toWatch ? "play.rectangle.on.rectangle" : "paperplane")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.linksAccent)
                if let chat {
                    Text(chat)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if feed == .toWatch, count > 0 {
                    Text("\(count)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        // No crossfade between entries: after a checkmark tap the fade could stall
                        // and leave the old number showing.
                        .contentTransition(.identity)
                }
                Link(destination: DeepLink.add.url) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("New Link")
            }
            if items.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: feed == .toWatch ? "checkmark.circle" : "paperplane")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text(feed == .toWatch ? "All caught up" : "Nothing sent yet")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ForEach(items) { item in
                    Row(item: item, feed: feed)
                        .transition(.identity)
                    if item.id != items.last?.id { Divider().padding(.leading, 50) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        // The whole list (count included) changes when a row is checked off, so mark all of it.
        .invalidatableContent()
        // No animated transition between entries: after a checkmark tap two reloads arrive close
        // together, and an interrupted transition could leave part of the old entry on screen.
        .contentTransition(.identity)
        .transaction { $0.animation = nil }
        .containerBackground(.background, for: .widget)
    }
}

private struct Row: View {
    let item: WidgetItem
    let feed: WidgetFeed

    var body: some View {
        HStack(spacing: 10) {
            Link(destination: DeepLink.open(linkID: item.id).url) {
                HStack(spacing: 10) {
                    ThumbnailImage(platform: item.platform, image: item.image, cornerRadius: 7)
                        .frame(width: 40, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if let receipt = item.receipt {
                            Text(receipt)
                                .font(.caption)
                                .foregroundStyle(item.seenByOthers ? Color.blue : .secondary)
                        } else {
                            Text("\(item.from) · \(item.ago)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if feed == .toWatch {
                // Interactive: marks it watched without opening the app.
                Button(intent: MarkWatchedIntent(linkID: item.id)) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark as Seen")
            }
        }
    }
}

// MARK: Lock Screen

private struct CircularView: View {
    let count: Int
    let feed: WidgetFeed

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: feed == .toWatch ? "play.fill" : "paperplane.fill")
                    .font(.caption)
                Text("\(count)")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .minimumScaleFactor(0.6)
            }
        }
        .widgetURL(DeepLink.inbox.url)
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel(feed == .toWatch ? "\(count) links to see" : "\(count) links sent")
    }
}

private struct RectangularView: View {
    let count: Int
    let items: [WidgetItem]
    let feed: WidgetFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(feed == .toWatch ? "\(count) to see" : "Sent", systemImage: feed == .toWatch ? "play.fill" : "paperplane.fill")
                .font(.headline)
                .widgetAccentable()
            if let item = items.first {
                Text(item.title).font(.caption).lineLimit(1)
                Text(item.receipt ?? "from \(item.from)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(feed == .toWatch ? "All caught up" : "Nothing sent yet").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(items.first.map { DeepLink.open(linkID: $0.id).url } ?? DeepLink.inbox.url)
        .containerBackground(.clear, for: .widget)
    }
}

private struct InlineView: View {
    let count: Int
    let feed: WidgetFeed

    var body: some View {
        Label(feed == .toWatch ? (count == 0 ? "All caught up" : "\(count) to see") : "Links sent",
              systemImage: feed == .toWatch ? "play.rectangle.on.rectangle" : "paperplane")
            .containerBackground(.clear, for: .widget)
    }
}

// MARK: Shared

private struct SignedOutView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "play.fill").font(.title2)
            Text("Open Links to sign in").font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding()
        .widgetURL(DeepLink.inbox.url)
    }
}

private struct BrandBackground: View {
    var body: some View {
        Rectangle().fill(Color.linksSurface)
    }
}

#Preview(as: .systemMedium) {
    LinksWidget()
} timeline: {
    LinksEntry.sample(feed: .toWatch)
    LinksEntry.sample(feed: .sent)
}

#Preview(as: .systemSmall) {
    LinksWidget()
} timeline: {
    LinksEntry.sample(feed: .toWatch)
}
