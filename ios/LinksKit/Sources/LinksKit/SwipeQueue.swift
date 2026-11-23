import Foundation

/// Swipe Through: the Queue as it was when opened, oldest first, one card each, then an end card.
/// It's a snapshot so cards stay put as they're marked seen.
public struct SwipeQueue: Sendable, Hashable, Identifiable {
    public let linkIDs: [Int]
    public var id: [Int] { linkIDs }

    public init(linkIDs: [Int]) {
        self.linkIDs = linkIDs
    }

    public init(_ inbox: InboxState, in groupID: Int? = nil) {
        linkIDs = inbox.links(for: .toWatch, in: groupID).sorted {
            $0.addedAt == $1.addedAt ? $0.id < $1.id : $0.addedAt < $1.addedAt
        }.map(\.id)
    }

    /// The links plus the end card.
    public var cardCount: Int { linkIDs.count + 1 }

    public func linkID(at card: Int) -> Int? {
        linkIDs.indices.contains(card) ? linkIDs[card] : nil
    }

    /// The links left behind by moving from one card to another: none going back, and every card
    /// skipped over going forward (a fast fling can pass more than one).
    public func passed(from: Int, to: Int) -> [Int] {
        guard to > from else { return [] }
        return Array(linkIDs[max(0, from)..<min(max(0, to), linkIDs.count)])
    }
}
