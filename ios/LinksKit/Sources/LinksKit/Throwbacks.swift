import Foundation

public extension InboxState {
    func throwbacks(in groupID: Int? = nil, now: Date = .now,
                    minimumAge: TimeInterval = 7 * 24 * 60 * 60) -> [SharedLink] {
        let cutoff = now.addingTimeInterval(-minimumAge)
        return links(for: .watched, in: groupID).filter { link in
            link.addedAt <= cutoff && !isBlocked(link.addedBy)
                && Self.isPositiveReaction(link.reactions[me])
                && !throwbackFriends(of: link).isEmpty
        }.sorted {
            $0.addedAt == $1.addedAt ? $0.id < $1.id : $0.addedAt < $1.addedAt
        }
    }

    func throwbackFriends(of link: SharedLink) -> [LinkUser] {
        users.filter {
            $0.id != me && $0.id != LinkUser.deletedID && !isBlocked($0.id)
                && Self.isPositiveReaction(link.reactions[$0.id])
        }.sorted { $0.id < $1.id }
    }

    static func throwbackStartIndex(count: Int, on date: Date = .now,
                                    calendar: Calendar = .current) -> Int {
        guard count > 0 else { return 0 }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0)),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        return ((days % count) + count) % count
    }

    internal static func isPositiveReaction(_ reaction: String?) -> Bool {
        reaction == "❤️" || reaction == "😂" || reaction == "🔥"
    }
}
