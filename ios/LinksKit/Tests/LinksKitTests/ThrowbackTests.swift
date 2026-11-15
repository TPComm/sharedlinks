import Foundation
import Testing
@testable import LinksKit

private let throwbackNow = Date(timeIntervalSince1970: 1_800_000_000)

private func oldFavorite(_ id: Int, daysAgo: Double = 30, groupID: Int = 1) -> SharedLink {
    SharedLink(id: id, groupID: groupID, url: URL(string: "https://example.com/\(id)")!,
               platform: .web, addedBy: "friend", addedAt: throwbackNow.addingTimeInterval(-daysAgo * 86400),
               seen: ["me": throwbackNow], reactions: ["me": "😂", "friend": "❤️"])
}

private func throwbackInbox(_ links: [SharedLink]) -> InboxState {
    InboxState(me: "me", users: [LinkUser(id: "me", name: "Me"), LinkUser(id: "friend", name: "Alex")],
               links: links)
}

@Test func throwbacksRequireAWeekAndTwoPositiveReactions() {
    let old = oldFavorite(1)
    let week = oldFavorite(2, daysAgo: 7)
    let recent = oldFavorite(3, daysAgo: 6.99)
    var unwatched = oldFavorite(4)
    unwatched.seen = [:]
    var mine = oldFavorite(5)
    mine.addedBy = "me"
    var alone = oldFavorite(6)
    alone.reactions["friend"] = nil
    var disliked = oldFavorite(7)
    disliked.reactions["me"] = "👎"
    var surprised = oldFavorite(8)
    surprised.reactions["friend"] = "😮"
    let inbox = throwbackInbox([old, week, recent, unwatched, mine, alone, disliked, surprised])
    #expect(inbox.throwbacks(now: throwbackNow).map(\.id) == [1, 2])
}

@Test func throwbacksStayInTheSelectedChatAndSortOldestFirst() {
    let inbox = throwbackInbox([oldFavorite(3), oldFavorite(2, daysAgo: 60),
                               oldFavorite(1, daysAgo: 60), oldFavorite(4, groupID: 2)])
    #expect(inbox.throwbacks(in: 1, now: throwbackNow).map(\.id) == [1, 2, 3])
    #expect(inbox.throwbacks(in: 2, now: throwbackNow).map(\.id) == [4])
    #expect(inbox.throwbacks(now: throwbackNow).count == 4)
    #expect(inbox.throwbacks(in: 99, now: throwbackNow).isEmpty)
}

@Test func throwbacksDoNotResurfaceBlockedDeletedOrUnknownPeople() {
    let link = oldFavorite(1)
    var inbox = throwbackInbox([link])
    inbox.blocked = ["friend"]
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    #expect(inbox.throwbackFriends(of: link).isEmpty)
    inbox.blocked = []
    inbox.users.removeAll { $0.id == "friend" }
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    inbox.users.append(LinkUser(id: LinkUser.deletedID, name: "Deleted user"))
    inbox.links[0].reactions[LinkUser.deletedID] = "😂"
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
}

@Test func removingAReactionOrMarkingUnwatchedRemovesAThrowback() {
    var inbox = throwbackInbox([oldFavorite(1)])
    #expect(inbox.throwbacks(now: throwbackNow).count == 1)
    inbox.links[0].reactions["me"] = nil
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    inbox.links[0].reactions["me"] = "🔥"
    inbox.links[0].seen["me"] = nil
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    #expect(InboxState.empty.throwbacks(now: throwbackNow).isEmpty)
}
