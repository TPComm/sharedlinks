import Foundation

public struct MonthlyRecap: Sendable {
    public struct Loved: Sendable {
        public let link: SharedLink
        public let emojiCounts: [String: Int]
    }

    public struct Sharer: Sendable {
        public let member: String
        public let count: Int
    }

    public struct Watcher: Sendable {
        public let member: String
        public let medianInterval: TimeInterval
        public let receiptCount: Int
    }

    public let month: DateInterval
    public let linkCount: Int
    public let sharerCount: Int
    public let mostLoved: Loved?
    public let topSharer: Sharer?
    public let fastestWatcher: Watcher?
}

public extension InboxState {
    func monthlyRecap(in group: Int, monthContaining date: Date = .now,
                      calendar: Calendar = .current) -> MonthlyRecap {
        let month = calendar.dateInterval(of: .month, for: date)!
        let members = Set(self.group(group)?.members ?? []).filter {
            $0 != LinkUser.deletedID && user($0) != nil && !isBlocked($0)
        }
        let links = self.group(group)?.members.contains(me) == true ? links(in: group).filter {
            $0.addedAt >= month.start && $0.addedAt < month.end && !isBlocked($0.addedBy)
        }.sorted {
            $0.addedAt == $1.addedAt ? $0.id > $1.id : $0.addedAt > $1.addedAt
        } : []
        let loved = links.map { link in
            MonthlyRecap.Loved(link: link, emojiCounts: link.reactions.reduce(into: [:]) { counts, reaction in
                if !isBlocked(reaction.key) { counts[reaction.value, default: 0] += 1 }
            })
        }.filter { !$0.emojiCounts.isEmpty }.sorted {
            let lhs = $0.emojiCounts.values.reduce(0, +)
            let rhs = $1.emojiCounts.values.reduce(0, +)
            if lhs != rhs { return lhs > rhs }
            if $0.link.addedAt != $1.link.addedAt { return $0.link.addedAt > $1.link.addedAt }
            return $0.link.id > $1.link.id
        }.first
        let shares = Dictionary(grouping: links.filter { members.contains($0.addedBy) }, by: \.addedBy)
        let top = shares.keys.sorted {
            let lhs = shares[$0]!, rhs = shares[$1]!
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs[0].addedAt != rhs[0].addedAt { return lhs[0].addedAt > rhs[0].addedAt }
            return lhs[0].id > rhs[0].id
        }.first.map { MonthlyRecap.Sharer(member: $0, count: shares[$0]!.count) }
        let watchers = members.compactMap { member -> MonthlyRecap.Watcher? in
            let intervals = links.compactMap { link -> TimeInterval? in
                guard member != link.addedBy, let seen = link.seen[member] else { return nil }
                let interval = seen.timeIntervalSince(link.addedAt)
                return interval >= 0 ? interval : nil
            }.sorted()
            guard intervals.count >= 2 else { return nil }
            let middle = intervals.count / 2
            let median = intervals.count.isMultiple(of: 2)
                ? (intervals[middle - 1] + intervals[middle]) / 2 : intervals[middle]
            return MonthlyRecap.Watcher(member: member, medianInterval: median, receiptCount: intervals.count)
        }.sorted {
            $0.medianInterval == $1.medianInterval ? $0.member < $1.member : $0.medianInterval < $1.medianInterval
        }
        return MonthlyRecap(month: month, linkCount: links.count,
                            sharerCount: Set(links.map(\.addedBy)).count, mostLoved: loved,
                            topSharer: top, fastestWatcher: watchers.first)
    }
}
