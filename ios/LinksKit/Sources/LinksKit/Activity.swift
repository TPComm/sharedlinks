import Foundation

public struct ActivityItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case comment, reaction, watched }

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
        if update != .newest || items.isEmpty {
            hasMore = page.hasMore
            next = page.next
        }
        var merged = Dictionary(uniqueKeysWithValues: (update == .reset ? [] : items).map { ($0.id, $0) })
        for item in page.items { merged[item.id] = item }
        items = merged.values.sorted { a, b in
            if a.at != b.at { return a.at > b.at }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            let aID = a.commentID ?? a.linkID
            let bID = b.commentID ?? b.linkID
            if aID != bID { return aID > bID }
            return a.person.utf8.lexicographicallyPrecedes(b.person.utf8)
        }
    }
}
