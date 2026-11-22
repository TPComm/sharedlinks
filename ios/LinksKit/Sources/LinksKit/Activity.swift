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
