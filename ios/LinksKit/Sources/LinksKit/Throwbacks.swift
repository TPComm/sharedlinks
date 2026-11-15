import Foundation

public extension InboxState {
    /// Already-watched links, at least a week old, that I and someone else enjoyed.
    func throwbacks(in groupID: Int? = nil, now: Date = .now) -> [SharedLink] {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return links(for: .watched, in: groupID).filter { link in
            link.addedAt <= cutoff && !isBlocked(link.addedBy)
                && Self.isThrowbackReaction(link.reactions[me])
                && !throwbackFriends(of: link).isEmpty
        }.sorted {
            $0.addedAt == $1.addedAt ? $0.id < $1.id : $0.addedAt < $1.addedAt
        }
    }

    func throwbackFriends(of link: SharedLink) -> [LinkUser] {
        users.filter { user in
            user.id != me && user.id != LinkUser.deletedID && !isBlocked(user.id)
                && Self.isThrowbackReaction(link.reactions[user.id])
        }.sorted { $0.id < $1.id }
    }

    private static func isThrowbackReaction(_ reaction: String?) -> Bool {
        reaction == "❤️" || reaction == "😂" || reaction == "🔥"
    }
}
