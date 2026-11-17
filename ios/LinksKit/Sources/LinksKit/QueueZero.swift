import Foundation

public extension InboxState {
    func queueZeroRecap(in groupID: Int? = nil, now: Date = .now) -> String {
        let start = now.addingTimeInterval(-7 * 86400)
        let cleared = links(in: groupID).filter { link in
            guard !isMine(link), let seen = link.seen[me] else { return false }
            return seen >= start && seen <= now
        }
        guard !cleared.isEmpty else { return "You've seen everything you were sent." }
        let senders = Set(cleared.map(\.addedBy)).sorted().map { name(of: $0) }
        let names = senders.count > 2
            ? "\(senders[0]), \(senders[1]) and \(senders.count - 2) \(senders.count == 3 ? "other" : "others")"
            : senders.joined(separator: " and ")
        return "You cleared \(cleared.count) \(cleared.count == 1 ? "link" : "links") in the last 7 days, from \(names)."
    }
}
