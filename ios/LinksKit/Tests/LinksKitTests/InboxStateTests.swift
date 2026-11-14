import Foundation
import Testing
@testable import LinksKit

/// Me, two friends, a legacy person waiting to be claimed, and links in server order (newest first).
let household: InboxState = {
    func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }
    func link(_ id: Int, _ url: String, _ platform: Platform, by: String, title: String? = nil, author: String? = nil,
              note: String = "", seen: [String: Date] = [:]) -> SharedLink {
        SharedLink(id: id, url: URL(string: url)!, platform: platform, title: title, author: author, note: note,
                   addedBy: by, addedAt: at(Double(id) * 100), seen: seen)
    }
    return InboxState(
        me: "user_ME",
        users: [LinkUser(id: "user_ME", name: "Me Myself"), LinkUser(id: "user_SAM", name: "Sam Lee"),
                LinkUser(id: "legacy:Jo", name: "Jo"), LinkUser(id: "user_ALEX", name: "Alex Kim")],
        links: [
            link(5, "https://www.tiktok.com/@/video/7301234567890123456", .tiktok, by: "user_SAM", title: "Cat dance",
                 author: "@catlover"),
            link(4, "https://www.youtube.com/watch?v=abc", .youtube, by: "user_ALEX", note: "the recipe I mentioned",
                 seen: ["user_ME": at(30), "user_SAM": at(20), "user_ALEX": at(10)]),
            link(3, "https://www.example.com/article", .web, by: "user_ME",
                 seen: ["user_ALEX": at(50), "user_SAM": at(40), "legacy:Jo": at(60)]),
            link(2, "https://www.instagram.com/reel/Cxyz", .instagram, by: "user_GONE"),
            link(1, "https://x.com/dev/status/1", .x, by: "user_SAM", seen: ["user_ME": at(5)]),
        ])
}()

@Suite("Inbox")
struct InboxStateTests {
    let state = household

    @Test func filtersKeepServerOrder() {
        #expect(state.links(for: .toWatch).map(\.id) == [5, 2])
        #expect(state.links(for: .watched).map(\.id) == [4, 1])
        #expect(state.links(for: .sent).map(\.id) == [3])
        #expect(state.links(for: .all).map(\.id) == [5, 4, 3, 2, 1])
        #expect(state.toWatch.map(\.id) == [5, 2])
    }

    @Test func everyLinkIsInExactlyOneOfToWatchWatchedSent() {
        let buckets: [InboxFilter] = [.toWatch, .watched, .sent]
        for link in state.links {
            #expect(buckets.filter { state.links(for: $0).contains(link) }.count == 1, "link \(link.id)")
        }
    }

    @Test func linkQuestions() throws {
        let mine = try #require(state.links.first { $0.id == 3 })
        let watched = try #require(state.links.first { $0.id == 4 })
        let fresh = try #require(state.links.first { $0.id == 5 })
        #expect(state.isMine(mine) && !state.isMine(watched))
        #expect(state.isSeenByMe(watched) && !state.isSeenByMe(fresh))
        #expect(state.isUnwatched(fresh))
        #expect(!state.isUnwatched(mine))  // my own links never need watching
        #expect(!state.isUnwatched(watched))
    }

    @Test func people() {
        #expect(state.meUser?.name == "Me Myself")
        #expect(state.user("user_SAM")?.name == "Sam Lee")
        #expect(state.user("nobody") == nil)
        #expect(state.name(of: "user_ALEX") == "Alex Kim")
        #expect(state.name(of: "user_GONE") == "Someone")
        #expect(state.name(of: LinkUser.deletedID) == "Deleted user") // their account was deleted
        // New links go to everyone who has signed in, in server order; not me, not legacy people.
        #expect(state.otherPeople.map(\.id) == ["user_SAM", "user_ALEX"])
    }

    @Test func seenByOthersIsEarliestFirstWithoutMeOrTheSender() throws {
        let mine = try #require(state.links.first { $0.id == 3 })
        let alexs = try #require(state.links.first { $0.id == 4 })
        #expect(state.seenByOthers(mine) == ["Sam Lee", "Alex Kim", "Jo"])
        #expect(state.seenByOthers(alexs) == ["Sam Lee"])
        #expect(state.seenByOthers(state.links[0]).isEmpty)
    }

    @Test(arguments: [
        ("cat", [5]),                    // title
        ("CAT DANCE", [5]),              // any case
        ("dance cat", [5]),              // words in any order
        ("@catlover", [5]),              // author
        ("recipe", [4]),                 // note
        ("alex", [4]),                   // sender's name
        ("someone", [2]),                // a sender we don't know
        ("example.com/article", [3]),    // the URL
        ("youtube", [4]),                // platform
        ("link", [3]),                   // the web's label
        ("sam", [5, 1]),
        ("cat recipe", []),              // every word has to match
        ("jo", []),                      // who watched it isn't searched
        ("", [5, 4, 3, 2, 1]),
        ("   \n", [5, 4, 3, 2, 1]),
    ])
    func search(_ query: String, _ ids: [Int]) {
        #expect(state.links(for: .all, matching: query).map(\.id) == ids)
    }

    @Test func searchStaysInsideTheFilter() {
        #expect(state.links(for: .toWatch, matching: "sam").map(\.id) == [5])
        #expect(state.links(for: .watched, matching: "sam").map(\.id) == [1])
        #expect(state.links(for: .sent, matching: "sam").isEmpty)
    }

    @Test func filterNames() {
        #expect(InboxFilter.allCases == [.toWatch, .watched, .sent, .all])
        #expect(InboxFilter.allCases.map(\.title) == ["To Watch", "Watched", "Sent", "All Links"])
        #expect(InboxFilter.allCases.allSatisfy { $0.id == $0 })
    }

    @Test func roundTripsThroughJSON() throws {
        let again = try APIClient.decoder.decode(InboxState.self, from: APIClient.encoder.encode(state))
        #expect(again == state)
    }
}
