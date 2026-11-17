import Foundation
import Testing
@testable import LinksKit

@Test func queueZeroRecapScopesRecentReceivedLinks() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func link(_ id: Int, sender: String = "ana", chat: Int = 1, age: TimeInterval = 0) -> SharedLink {
        SharedLink(id: id, groupID: chat, url: URL(string: "https://example.com/\(id)")!,
                   platform: .web, addedBy: sender, addedAt: now,
                   seen: ["me": now.addingTimeInterval(-age)])
    }
    var inbox = InboxState(me: "me", users: [LinkUser(id: "ana", name: "Ana"),
                                            LinkUser(id: "ben", name: "Ben")],
                           links: [link(1), link(2, sender: "ben"), link(3, chat: 2),
                                   link(4, age: 7 * 86400 + 1), link(5, sender: "me"), link(6, age: -1)])
    #expect(inbox.queueZeroRecap(in: 1, now: now) == "You cleared 2 links in the last 7 days, from Ana and Ben.")
    #expect(inbox.queueZeroRecap(in: 2, now: now) == "You cleared 1 link in the last 7 days, from Ana.")
    inbox.links = [link(1, age: 7 * 86400), link(2, sender: "ben"), link(3, sender: "unknown")]
    #expect(inbox.queueZeroRecap(now: now) == "You cleared 3 links in the last 7 days, from Ana, Ben and 1 other.")
    inbox.links = [link(1, sender: "unknown")]
    #expect(inbox.queueZeroRecap(now: now) == "You cleared 1 link in the last 7 days, from Someone.")
    inbox.links[0].seen = [:]
    #expect(inbox.queueZeroRecap(now: now) == "You've seen everything you were sent.")
    #expect(InboxState.empty.queueZeroRecap(now: now) == "You've seen everything you were sent.")
}
