import Foundation

public struct ActivityReadState: Codable, Sendable {
    private var viewed: [String: Date] = [:]
    private var read: [String: Set<String>] = [:]
    private static let key = "activityReadState"

    public init() {}

    private func scope(_ person: String, _ server: URL) -> String { "\(server.absoluteString)|\(person)" }

    public func isNew(_ date: Date, person: String, server: URL) -> Bool {
        date > (viewed[scope(person, server)] ?? .distantPast)
    }

    public func hasUnread(_ item: ActivityItem, threadReads: CommentReadState = CommentReadState(), person: String, server: URL) -> Bool {
        threadReads.hasUnread(item, person: person, server: server)
            && !(read[scope(person, server)]?.contains(item.id) ?? false)
    }

    public mutating func markRead(_ item: ActivityItem, person: String, server: URL) {
        read[scope(person, server), default: []].insert(item.id)
    }

    public mutating func markViewed(through date: Date, person: String, server: URL) {
        let key = scope(person, server)
        viewed[key] = max(viewed[key] ?? .distantPast, date)
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key) else { return Self() }
        return (try? APIClient.decoder.decode(Self.self, from: data)) ?? Self()
    }

    public func save(defaults: UserDefaults = .standard) {
        guard let data = try? APIClient.encoder.encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

public struct ActivityItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case comment, reaction, seen }

    public let kind: Kind
    public let linkID: Int
    public let person: String
    public let at: Date
    public let commentID: Int?
    public let snippet: String?
    public let emoji: String?

    public var id: String { "\(kind.rawValue):\(linkID):\(person):\(commentID ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case kind, person, at, snippet, emoji
        case linkID = "link_id"
        case commentID = "comment_id"
    }
}

public struct ActivityPage: Codable, Sendable {
    public let items: [ActivityItem]
    public let hasMore: Bool
    public let next: String?

    enum CodingKeys: String, CodingKey {
        case items, next
        case hasMore = "has_more"
    }
}

public struct ActivityFeed: Sendable {
    public enum Update { case reset, older, newest }

    public private(set) var items: [ActivityItem] = []
    public private(set) var hasMore = false
    public private(set) var next: String?

    public init() {}

    public mutating func apply(_ page: ActivityPage, update: Update) {
        if update != .newest || items.isEmpty || !page.hasMore {
            hasMore = page.hasMore
            next = page.next
        }
        let retained: [ActivityItem]
        if update == .reset || (update == .newest && !page.hasMore) {
            retained = []
        } else if update == .newest, let last = page.items.last {
            retained = items.filter { Self.precedes(last, $0) }
        } else {
            retained = items
        }
        var merged = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        for item in page.items { merged[item.id] = item }
        items = merged.values.sorted(by: Self.precedes)
    }

    private static func precedes(_ a: ActivityItem, _ b: ActivityItem) -> Bool {
        if a.at != b.at { return a.at > b.at }
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        let aID = a.commentID ?? a.linkID
        let bID = b.commentID ?? b.linkID
        if aID != bID { return aID > bID }
        return a.person.utf8.lexicographicallyPrecedes(b.person.utf8)
    }
}
