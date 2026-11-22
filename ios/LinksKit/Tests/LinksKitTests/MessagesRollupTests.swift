import Foundation
import Testing
@testable import LinksKit

private let rollupHost = "links.example.com"

private func rollupLink(_ id: Int, group: Int = 1, at: Date, sender: String = "me") -> SharedLink {
    SharedLink(id: id, groupID: group, url: URL(string: "https://example.com/\(id)")!,
               platform: .web, title: "Title \(id)", addedBy: sender, addedAt: at,
               token: "token-\(id)", shareURL: URL(string: "https://\(rollupHost)/l/token-\(id)")!)
}

private func rollupState(_ links: [SharedLink]) -> InboxState {
    InboxState(me: "me", users: [LinkUser(id: "friend", name: "Friend")],
               groups: [LinkGroup(id: 1, members: ["me", "friend"]), LinkGroup(id: 2, name: "Family")], links: links)
}

@Test func rollupsUseLocalDayAndOnlyMyValidLinks() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 12 * 3600)!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try #require(calendar.dateInterval(of: .day, for: now))
    var invalid = rollupLink(5, at: now)
    invalid.shareURL = URL(string: "https://links.example.com/l/bad!")
    let state = rollupState([
        rollupLink(1, at: day.start), rollupLink(2, at: day.start.addingTimeInterval(-1)),
        rollupLink(3, at: day.end), rollupLink(4, at: now, sender: "friend"), invalid,
        rollupLink(6, group: 2, at: now), rollupLink(7, at: day.start.addingTimeInterval(1))
    ])
    let rollups = MessagesRollup.today(in: state, now: now, calendar: calendar)
    #expect(rollups.map(\.id) == [2, 1])
    #expect(rollups.map(\.chatName) == ["Family", "Friend"])
    #expect(rollups[1].links.map(\.id) == [7, 1])
    #expect(MessagesRollup.today(in: rollupState([]), now: now).isEmpty)
}

@Test func rollupCopyAndURLCap() throws {
    let now = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600)
    let links = (1...1000).map { rollupLink($0, at: now.addingTimeInterval(-Double($0))) }
    let rollup = try #require(MessagesRollup.today(in: rollupState(links), now: now).first)
    #expect(rollup.caption == "1000 links from today")
    #expect(rollup.subcaption == "Title 1, Title 2 and 998 more")
    #expect(rollup.detail == "1000 links to Friend")
    let url = try #require(rollup.url(associatedDomain: rollupHost))
    #expect(url.absoluteString.count <= 5000)
    #expect(url.path == "/g/1")
    let selection = try #require(MessagesRollupSelection(url: url, associatedDomain: rollupHost))
    #expect(!selection.tokens.isEmpty && selection.tokens.count < 1000)
    #expect(selection.tokens == Array(links.prefix(selection.tokens.count)).compactMap(\.token))
    #expect(rollup.url(associatedDomain: nil) == nil)
    let single = try #require(MessagesRollup.today(in: rollupState([rollupLink(1, at: now)]), now: now).first)
    #expect(single.caption == "1 link from today")
    #expect(single.detail == "1 link to Friend")
    #expect(single.subcaption == "Title 1")
    #expect(single.url(associatedDomain: rollupHost)?.absoluteString == "https://links.example.com/g/1?links=token-1")
}

@Test func rollupSelectionValidatesHostCredentialsAndTokens() throws {
    for scheme in ["http", "https"] {
        let selection = try #require(MessagesRollupSelection(
            url: URL(string: "\(scheme)://\(rollupHost)/g/1?links=token-1,bad%21,token-2,," + String(repeating: "a", count: 65)),
            associatedDomain: rollupHost))
        #expect(selection.groupID == "1")
        #expect(selection.tokens == ["token-1", "token-2"])
        #expect(selection.links(in: rollupState([rollupLink(1, at: .now), rollupLink(2, group: 2, at: .now)])).map(\.id) == [1])
    }
    for raw in ["https://foreign.example/g/1?links=a", "https://user@\(rollupHost)/g/1?links=a",
                "https://user:pass@\(rollupHost)/g/1?links=a", "sharedlinks://g/1?links=a",
                "https://\(rollupHost)/g/bad!?links=a", "https://\(rollupHost)/g/1",
                "https://\(rollupHost)/l/token-1?links=a"] {
        #expect(MessagesRollupSelection(url: URL(string: raw), associatedDomain: rollupHost) == nil)
    }
    #expect(MessagesRollupSelection(url: nil, associatedDomain: rollupHost) == nil)
    #expect(MessagesRollupSelection(url: URL(string: "https://\(rollupHost)/g/1?links=bad!"), associatedDomain: rollupHost)?.tokens == [])
}

@Test func rollupInsertionRejectsStaleIdentityConversationAndLinks() throws {
    let now = Date.now
    let user = LinkUser(id: "me", name: "Me")
    let links = [rollupLink(1, at: now)]
    let rollups = MessagesRollup.today(in: rollupState(links), now: now)
    let rollup = try #require(rollups.first)
    #expect(MessagesRollupInsertion(rollup: rollup, token: nil, currentUser: user) == nil)
    #expect(MessagesRollupInsertion(rollup: rollup, token: "session", currentUser: nil) == nil)
    let insertion = try #require(MessagesRollupInsertion(rollup: rollup, token: "session", currentUser: user))
    #expect(insertion.canInsert(token: "session", currentUser: user, conversationMatches: true, rollups: rollups))
    #expect(!insertion.canInsert(token: "other", currentUser: user, conversationMatches: true, rollups: rollups))
    #expect(!insertion.canInsert(token: "session", currentUser: LinkUser(id: "other", name: "Other"), conversationMatches: true, rollups: rollups))
    #expect(!insertion.canInsert(token: "session", currentUser: user, conversationMatches: false, rollups: rollups))
    #expect(!insertion.canInsert(token: "session", currentUser: user, conversationMatches: true, rollups: []))
    let changed = MessagesRollup.today(in: rollupState(links + [rollupLink(2, at: now)]), now: now)
    #expect(!insertion.canInsert(token: "session", currentUser: user, conversationMatches: true, rollups: changed))
}
