import Foundation
import Testing
@testable import LinksKit

private func pickLink(_ id: Int, chat: Int = 1, sender: String = "friend", date: TimeInterval = 100,
                      seen: [String: Date] = [:]) -> SharedLink {
    SharedLink(id: id, groupID: chat, url: URL(string: "https://example.invalid/\(id)")!,
               platform: .web, addedBy: sender, addedAt: Date(timeIntervalSince1970: date), seen: seen)
}

private func pickInbox(_ links: [SharedLink]) -> InboxState {
    InboxState(me: "me", users: [LinkUser(id: "me", name: "Matt"), LinkUser(id: "friend", name: "Jeremy"),
                                LinkUser(id: "third", name: "Sam")],
               groups: [LinkGroup(id: 1, members: ["me", "friend", "third"])], links: links)
}

@Test func tonightsPickRanksByUnwatchedPeopleNotRecencyOrMyQueue() {
    let inbox = pickInbox([pickLink(1, sender: "me"), pickLink(2, date: 200, seen: ["third": .now]),
                           pickLink(3, chat: 2, date: 300)])
    #expect(inbox.tonightsPick(in: 1)?.link.id == 1)
    #expect(inbox.tonightsPick(in: 1)?.unwatched == ["friend", "third"])
    #expect(inbox.tonightsPick(in: 99) == nil)
}

@Test func tonightsPickUsesNewestThenIDForStableTies() {
    let inbox = pickInbox([pickLink(1), pickLink(2, date: 200), pickLink(3, date: 200)])
    #expect(inbox.tonightsPick(in: 1)?.link.id == 3)
}

@Test func tonightsPickUsesSeenNotReactionsAndIncludesMeButNeverTheSender() {
    var inbox = pickInbox([pickLink(1)])
    inbox.links[0].reactions = ["me": "🔥", "third": "❤️"]
    #expect(inbox.tonightsPick(in: 1)?.unwatched == ["me", "third"])
    inbox.links[0].seen["me"] = .now
    #expect(inbox.tonightsPick(in: 1)?.unwatched == ["third"])
    inbox.links[0].seen["third"] = .now
    #expect(inbox.tonightsPick(in: 1) == nil)
    inbox.links[0].seen["third"] = nil
    #expect(inbox.tonightsPick(in: 1)?.link.id == 1)
}

@Test func tonightsPickFollowsMembershipAndVisibleLinkRemoval() {
    var inbox = pickInbox([pickLink(1, seen: ["me": .now])])
    inbox.links[0].seen["outsider"] = .now
    #expect(inbox.tonightsPick(in: 1)?.unwatched == ["third"])
    inbox.groups[0].members.removeAll { $0 == "third" }
    #expect(inbox.tonightsPick(in: 1) == nil)
    inbox.groups[0].members.append("third")
    inbox.groups[0].members.append("third")
    #expect(inbox.tonightsPick(in: 1)?.unwatched == ["third"])
    inbox.links.removeAll()
    #expect(inbox.tonightsPick(in: 1) == nil)
    #expect(pickInbox([pickLink(1)]).leaving(group: 1).tonightsPick(in: 1) == nil)
}

@Test func tonightsPickDoesNotTreatMissingReceiptsFromBlockedPeopleAsUnwatched() {
    var inbox = pickInbox([pickLink(1)])
    inbox.blocked = ["third"]
    #expect(inbox.tonightsPick(in: 1) == nil)
    inbox.blocked = []
    inbox.users.removeAll { $0.id == "third" }
    #expect(inbox.tonightsPick(in: 1) == nil)
    inbox.groups[0].members = ["me", "friend", LinkUser.deletedID]
    #expect(inbox.tonightsPick(in: 1) == nil)
    inbox.groups[0].members = ["me", "friend"]
    inbox.links[0].addedBy = "third"
    inbox.blocked = ["third"]
    #expect(inbox.tonightsPick(in: 1) == nil)
}

@Test func tonightsPickNeedsAChatWithMeAndSomeoneElse() {
    var inbox = pickInbox([pickLink(1)])
    for members in [[], ["me"], ["me", "me"], ["friend", "third"]] {
        inbox.groups[0].members = members
        #expect(inbox.tonightsPick(in: 1) == nil)
    }
    #expect(InboxState.empty.tonightsPick(in: 1) == nil)
}
