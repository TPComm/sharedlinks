import Foundation

public struct TonightsPick: Sendable, Equatable {
    public let link: SharedLink
    /// Current chat members without a Seen mark, excluding the sender (as in Queue).
    public let unwatched: [String]
}

public extension InboxState {
    /// The visible chat link still in the most people's queues. Newest wins a tie.
    func tonightsPick(in groupID: Int) -> TonightsPick? {
        guard let group = group(groupID), group.members.contains(me), Set(group.members).count >= 2,
              group.members.allSatisfy({ $0 != LinkUser.deletedID && user($0) != nil && !isBlocked($0) }) else {
            // A blocked person's receipts are omitted by the server, not evidence they haven't watched.
            return nil
        }
        let members = group.members.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        return links(in: groupID).filter { !isBlocked($0.addedBy) }.compactMap { link in
            let unwatched = members.filter { $0 != link.addedBy && link.seen[$0] == nil }
            return unwatched.isEmpty ? nil : TonightsPick(link: link, unwatched: unwatched)
        }.sorted {
            if $0.unwatched.count != $1.unwatched.count { return $0.unwatched.count > $1.unwatched.count }
            if $0.link.addedAt != $1.link.addedAt { return $0.link.addedAt > $1.link.addedAt }
            return $0.link.id > $1.link.id
        }.first
    }
}
