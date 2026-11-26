import Foundation
import Testing
@testable import LinksKit

private func tasteLink(_ id: Int, chat: Int = 1, date: TimeInterval = 100,
                       reactions: [String: String] = ["me": "❤️", "friend": "🔥"]) -> SharedLink {
    SharedLink(id: id, groupID: chat, url: URL(string: "https://example.invalid/\(id)")!,
               platform: .web, addedBy: "friend", addedAt: Date(timeIntervalSince1970: date), reactions: reactions)
}

private func tasteInbox(_ links: [SharedLink]) -> InboxState {
    InboxState(me: "me", users: [LinkUser(id: "me", name: "Matt"), LinkUser(id: "friend", name: "Jeremy"),
                                LinkUser(id: "third", name: "Sam")],
               groups: [LinkGroup(id: 1, members: ["me", "friend"])], links: links)
}

@Test func tasteMatchesRequireEveryCurrentMemberToReactPositively() {
    var inbox = tasteInbox([tasteLink(1)])
    #expect(inbox.tasteMatches(in: 1).map(\.id) == [1])
    for reaction in ["❤️", "😂", "🔥"] {
        inbox.links[0].reactions = ["me": reaction, "friend": reaction]
        #expect(inbox.tasteMatches(in: 1).count == 1)
    }
    for reactions in [["me": "❤️"], ["friend": "❤️"], ["me": "😮", "friend": "❤️"],
                      ["me": "❤️", "friend": "👎"], ["me": "❤️", "friend": "🫶"], ["me": "❤️", "third": "🔥"]] {
        inbox.links[0].reactions = reactions
        #expect(inbox.tasteMatches(in: 1).isEmpty)
    }
}

@Test func tasteMatchesAreChatScopedAndNewestFirstWithoutAnAgeOrSeenRequirement() {
    var inbox = tasteInbox([tasteLink(1), tasteLink(3), tasteLink(2, date: 200), tasteLink(4, chat: 2)])
    inbox.links[0].addedBy = "me"
    #expect(inbox.tasteMatches(in: 1).map(\.id) == [2, 3, 1])
    #expect(inbox.tasteMatches(in: 99).isEmpty)
    #expect(inbox.tasteMatches(in: 1).allSatisfy { $0.seen.isEmpty })
}

@Test func tasteMatchesFollowMembershipAndReactionChanges() {
    var inbox = tasteInbox([tasteLink(1)])
    inbox.groups[0].members.append("third")
    #expect(inbox.tasteMatches(in: 1).isEmpty)
    inbox.links[0].reactions["third"] = "😂"
    #expect(inbox.tasteMatches(in: 1).count == 1)
    inbox.links[0].reactions["friend"] = nil
    #expect(inbox.tasteMatches(in: 1).isEmpty)
    inbox.groups[0].members.removeAll { $0 == "friend" }
    #expect(inbox.tasteMatches(in: 1).count == 1)
    inbox.groups[0].members.removeAll { $0 == "me" }
    #expect(inbox.tasteMatches(in: 1).isEmpty)
}

@Test func tasteMatchesDoNotDropBlockedUnknownOrDeletedMembersToInventUnanimity() {
    var inbox = tasteInbox([tasteLink(1)])
    inbox.blocked = ["friend"]
    #expect(inbox.tasteMatches(in: 1).isEmpty)
    inbox.blocked = []
    inbox.users.removeAll { $0.id == "friend" }
    #expect(inbox.tasteMatches(in: 1).isEmpty)
    inbox.users.append(LinkUser(id: "friend", name: "Jeremy"))
    inbox.groups[0].members.append(LinkUser.deletedID)
    inbox.links[0].reactions[LinkUser.deletedID] = "❤️"
    #expect(inbox.tasteMatches(in: 1).isEmpty)
    inbox.groups[0].members = ["me", "friend"]
    inbox.links[0].addedBy = "third"
    inbox.blocked = ["third"]
    #expect(inbox.tasteMatches(in: 1).isEmpty)
}

@Test func tasteMatchesNeedAtLeastTwoMembersAndIgnoreOutsiderReactions() {
    var inbox = tasteInbox([tasteLink(1)])
    inbox.links[0].reactions["third"] = "👎"
    #expect(inbox.tasteMatches(in: 1).count == 1)
    for members in [[], ["me"], ["me", "me"]] {
        inbox.groups[0].members = members
        #expect(inbox.tasteMatches(in: 1).isEmpty)
    }
    #expect(InboxState.empty.tasteMatches(in: 1).isEmpty)
}

@Test func tasteMatchSummaryNamesThePairOrTheWholeGroup() {
    var inbox = tasteInbox([])
    #expect(inbox.tasteMatchSummary(in: 1, count: 12) == "You and Jeremy both loved 12 links")
    #expect(inbox.tasteMatchSummary(in: 1, count: 1) == "You and Jeremy both loved 1 link")
    inbox.groups[0].members.append("third")
    #expect(inbox.tasteMatchSummary(in: 1, count: 2) == "All 3 of you loved 2 links")
}

@Test func tasteMatchesFollowVisibleLinkAndGroupRemoval() {
    var inbox = tasteInbox([tasteLink(1), tasteLink(2)])
    inbox.links.removeAll { $0.id == 1 }
    #expect(inbox.tasteMatches(in: 1).map(\.id) == [2])
    inbox = inbox.leaving(group: 1)
    #expect(inbox.tasteMatches(in: 1).isEmpty)
}
