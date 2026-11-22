import Foundation
import Testing
@testable import LinksKit

private let throwbackNow = Date(timeIntervalSince1970: 1_800_000_000)

private func favorite(_ id: Int, age: TimeInterval = 30 * 86400, chat: Int = 1) -> SharedLink {
    SharedLink(id: id, groupID: chat, url: URL(string: "https://example.com/\(id)")!,
               platform: .web, addedBy: "friend", addedAt: throwbackNow.addingTimeInterval(-age),
               seen: ["me": throwbackNow], reactions: ["me": "😂", "friend": "❤️"])
}

private func favoritesInbox(_ links: [SharedLink]) -> InboxState {
    InboxState(me: "me", users: [LinkUser(id: "me", name: "Me"), LinkUser(id: "friend", name: "Alex")], links: links)
}

@Test func throwbacksRequireOldWatchedLinksAndPositiveReactions() {
    let week: TimeInterval = 7 * 86400
    var inbox = favoritesInbox([favorite(1, age: week), favorite(2, age: week - 1)])
    #expect(inbox.throwbacks(now: throwbackNow).map(\.id) == [1])
    for reactions in [["friend": "❤️"], ["me": "👎", "friend": "❤️"],
                      ["me": "❤️", "friend": "😮"], ["me": "❤️", "friend": "🫶"], ["me": "🔥"]] {
        inbox.links[0].reactions = reactions
        #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    }
    inbox.links[0].reactions = ["me": "🔥", "friend": "😂"]
    #expect(inbox.throwbacks(now: throwbackNow).count == 1)
    inbox.links[0].seen = [:]
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    inbox.links[0].seen = ["me": throwbackNow]
    inbox.links[0].addedBy = "me"
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
}

@Test func throwbacksFilterChatsAndSortOldestThenID() {
    let inbox = favoritesInbox([favorite(3), favorite(2, age: 60 * 86400),
                                favorite(1, age: 60 * 86400), favorite(4, chat: 2)])
    #expect(inbox.throwbacks(in: 1, now: throwbackNow).map(\.id) == [1, 2, 3])
    #expect(inbox.throwbacks(in: 2, now: throwbackNow).map(\.id) == [4])
    #expect(inbox.throwbacks(now: throwbackNow).map(\.id) == [1, 2, 3, 4])
    #expect(inbox.throwbacks(in: 99, now: throwbackNow).isEmpty)
}

@Test func throwbacksExcludeBlockedDeletedAndUnknownFriends() {
    var inbox = favoritesInbox([favorite(1)])
    inbox.links[0].addedBy = "sender"
    inbox.blocked = ["sender"]
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    inbox.blocked = ["friend"]
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    #expect(inbox.throwbackFriends(of: inbox.links[0]).isEmpty)
    inbox.blocked = []
    inbox.users.removeAll { $0.id == "friend" }
    inbox.users.append(LinkUser(id: LinkUser.deletedID, name: "Deleted user"))
    inbox.links[0].reactions[LinkUser.deletedID] = "❤️"
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    #expect(inbox.throwbackFriends(of: inbox.links[0]).isEmpty)
}

@Test func throwbackFriendsAreSortedAndExcludeMe() {
    var inbox = favoritesInbox([favorite(1)])
    inbox.users.append(LinkUser(id: "another", name: "Sam"))
    inbox.links[0].reactions["another"] = "🔥"
    #expect(inbox.throwbackFriends(of: inbox.links[0]).map(\.id) == ["another", "friend"])
}

@Test func throwbacksUpdateWhenReactionsOrWatchedStatusChange() {
    var inbox = favoritesInbox([favorite(1)])
    #expect(inbox.throwbacks(now: throwbackNow).count == 1)
    inbox.links[0].reactions["friend"] = nil
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    inbox.links[0].reactions["friend"] = "🔥"
    inbox.links[0].reactions["me"] = nil
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    inbox.links[0].reactions["me"] = "❤️"
    inbox.links[0].seen["me"] = nil
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    #expect(InboxState.empty.throwbacks(now: throwbackNow).isEmpty)
}

@Test func throwbackMinimumAgeCanBeOverridden() {
    let inbox = favoritesInbox([favorite(1, age: 0)])
    #expect(inbox.throwbacks(now: throwbackNow).isEmpty)
    #expect(inbox.throwbacks(now: throwbackNow, minimumAge: 0).map(\.id) == [1])
    #expect(inbox.throwbacks(now: throwbackNow, minimumAge: 1).isEmpty)
}

@Test func throwbackStartIndexRotatesByCalendarDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = calendar.startOfDay(for: throwbackNow)
    let index = InboxState.throwbackStartIndex(count: 3, on: day, calendar: calendar)
    #expect(InboxState.throwbackStartIndex(count: 3, on: day.addingTimeInterval(86399), calendar: calendar) == index)
    #expect(InboxState.throwbackStartIndex(count: 3, on: day.addingTimeInterval(86400), calendar: calendar) == (index + 1) % 3)
    #expect(InboxState.throwbackStartIndex(count: 3, on: day.addingTimeInterval(3 * 86400), calendar: calendar) == index)
    #expect(InboxState.throwbackStartIndex(count: 0, on: day, calendar: calendar) == 0)
    #expect(InboxState.throwbackStartIndex(count: 1, on: day, calendar: calendar) == 0)
    let beforeReference = Date(timeIntervalSinceReferenceDate: -86400)
    #expect((0..<3).contains(InboxState.throwbackStartIndex(count: 3, on: beforeReference, calendar: calendar)))
}
