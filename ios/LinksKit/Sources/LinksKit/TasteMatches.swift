import Foundation

public extension InboxState {
    /// Unanimous favorites among current members, using only this reader's visible chat links.
    func tasteMatches(in groupID: Int) -> [SharedLink] {
        guard let group = group(groupID), group.members.contains(me), Set(group.members).count >= 2,
              group.members.allSatisfy({ $0 != LinkUser.deletedID && user($0) != nil && !isBlocked($0) }) else {
            return []
        }
        return links(in: groupID).filter { link in
            !isBlocked(link.addedBy) && group.members.allSatisfy { Self.isPositiveReaction(link.reactions[$0]) }
        }.sorted {
            $0.addedAt == $1.addedAt ? $0.id > $1.id : $0.addedAt > $1.addedAt
        }
    }

    func tasteMatchSummary(in groupID: Int, count: Int) -> String {
        let members = Set(group(groupID)?.members ?? [])
        let links = count == 1 ? "1 link" : "\(count.formatted()) links"
        if members.count == 2, let friend = members.first(where: { $0 != me }) {
            return "You and \(name(of: friend)) both loved \(links)"
        }
        return "All \(members.count.formatted()) of you loved \(links)"
    }
}
