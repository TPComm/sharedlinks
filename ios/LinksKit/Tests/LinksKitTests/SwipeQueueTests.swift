import Foundation
import Testing
@testable import LinksKit

@Suite("Swipe Through")
struct SwipeQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func link(_ id: Int, age: TimeInterval, by sender: String = "friend", chat: Int = 1,
                      seen: Bool = false) -> SharedLink {
        SharedLink(id: id, groupID: chat, url: URL(string: "https://example.com/\(id)")!, platform: .web,
                   addedBy: sender, addedAt: now.addingTimeInterval(-age), seen: seen ? ["me": now] : [:])
    }

    private func inbox(_ links: [SharedLink]) -> InboxState {
        InboxState(me: "me", users: [LinkUser(id: "me", name: "Me"), LinkUser(id: "friend", name: "Alex")],
                   links: links)
    }

    @Test func takesTheQueueOldestFirst() {
        let state = inbox([link(1, age: 10), link(2, age: 30), link(3, age: 20), link(4, age: 20)])
        #expect(SwipeQueue(state).linkIDs == [2, 3, 4, 1])
        #expect(SwipeQueue(state).cardCount == 5)
    }

    @Test func leavesOutSeenAndSentLinksAndOtherChats() {
        let state = inbox([link(1, age: 10), link(2, age: 20, seen: true), link(3, age: 30, by: "me"),
                           link(4, age: 40, chat: 2)])
        #expect(SwipeQueue(state).linkIDs == [4, 1])
        #expect(SwipeQueue(state, in: 1).linkIDs == [1])
        #expect(SwipeQueue(state, in: 3).linkIDs.isEmpty)
        #expect(SwipeQueue(state, in: 3).cardCount == 1)
    }

    @Test func movingForwardPassesEachCardLeftBehind() {
        let queue = SwipeQueue(linkIDs: [7, 8, 9])
        #expect(queue.passed(from: 0, to: 1) == [7])
        #expect(queue.passed(from: 1, to: 3) == [8, 9])
        #expect(queue.passed(from: 2, to: 3) == [9], "swiping onto the end card passes the last link")
        #expect(queue.passed(from: 3, to: 4).isEmpty)
        #expect(queue.passed(from: 2, to: 1).isEmpty, "going back never unmarks")
        #expect(queue.passed(from: 1, to: 1).isEmpty)
        #expect(queue.linkID(at: 2) == 9)
        #expect(queue.linkID(at: 3) == nil)
    }
}
