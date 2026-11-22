import Foundation
import Testing
@testable import LinksKit

/// The household, in chats: everyone in the default one, Sam and me in "Film club",
/// and an unnamed chat with Alex.
let chats: InboxState = {
    var state = household
    state.groups = [
        LinkGroup(id: 1, name: "", isDefault: true, members: ["user_ME", "user_SAM", "user_ALEX", "user_GONE"]),
        LinkGroup(id: 2, name: "Film club", createdBy: "user_SAM", members: ["user_SAM", "user_ME"]),
        LinkGroup(id: 3, createdBy: "user_ME", members: ["user_ME", "user_ALEX"]),
    ]
    let chatOf = [5: 2, 4: 1, 3: 3, 2: 1, 1: 1]
    state.links = state.links.map { link in
        var link = link
        link.groupID = chatOf[link.id]
        return link
    }
    return state
}()

@Suite("Chats")
struct GroupsTests {
    let state = chats

    @Test func decodesStateWithChats() throws {
        let json = #"""
        {"me": "user_01SAM", "users": [\#(Fixture.sam)], "blocked": [],
         "groups": [\#(Fixture.group(id: 1, name: "Everyone", isDefault: true, members: #"["user_01SAM"]"#)), \#(Fixture.group())],
         "links": [\#(Fixture.link(id: 7, groupID: 5))]}
        """#
        let state = try Fixture.decode(InboxState.self, json)
        #expect(state.groups.map(\.id) == [1, 5])
        #expect(state.defaultGroup?.id == 1)
        let film = try #require(state.group(5))
        #expect(film.name == "Film club" && film.createdBy == "user_01SAM" && !film.isDefault && !film.isDirect)
        #expect(film.members == ["user_01SAM", "user_01JO"])
        #expect(film.createdAt == Date(timeIntervalSince1970: 1_794_525_700))
        #expect(state.links.first?.groupID == 5)
    }

    @Test func directChatKeepsItsPeerWhileTheyShareAGroup() throws {
        let direct = try Fixture.decode(LinkGroup.self, #"{"id": 4, "direct": true, "members": ["user_ME", "user_ALEX"]}"#)
        var state = state.updating(direct)
        #expect(direct.isDirect && state.title(of: direct) == "Alex Kim")
        #expect(!state.canLeave(direct))
        state.groups = [direct]
        #expect(state.canLeave(direct))
    }

    @Test func aBlockedPersonWithoutAnySharedChatIsNotInPeople() {
        var state = state
        state.groups = []
        state.blocked = ["user_ALEX"]
        #expect(!state.otherPeople.map(\.id).contains("user_ALEX"))
    }

    /// Cached inboxes and servers from before chats: no groups, no group_id.
    @Test func decodesStateFromBeforeChats() throws {
        let json = #"{"me": "user_01SAM", "users": [\#(Fixture.sam)], "links": [\#(Fixture.link(groupID: nil))]}"#
        let state = try Fixture.decode(InboxState.self, json)
        #expect(state.groups.isEmpty && state.defaultGroup == nil && !state.hasChats)
        #expect(state.links.first?.groupID == nil)
        #expect(state.links(for: .all, in: nil).count == 1)
        #expect(state.recipients(in: nil).map(\.id) == state.otherPeople.map(\.id))
    }

    @Test func aBadChatDoesNotTakeDownTheInbox() throws {
        let json = #"{"me": "user_01SAM", "users": [], "links": [], "groups": [{"name": "no id"}, \#(Fixture.group())]}"#
        #expect(try Fixture.decode(InboxState.self, json).groups.map(\.id) == [5])
    }

    @Test func roundTripsThroughTheSnapshot() throws {
        // Once through first: seconds since 1970 as a Double don't round-trip every Date exactly.
        let saved = try APIClient.decoder.decode(InboxState.self, from: APIClient.encoder.encode(state))
        let again = try APIClient.decoder.decode(InboxState.self, from: APIClient.encoder.encode(saved))
        #expect(again == saved)
        #expect(saved.groups.map(\.id) == [1, 2, 3])
        #expect(saved.links.map(\.groupID) == state.links.map(\.groupID))
    }

    @Test func filtersByChatWithinEachList() {
        #expect(state.links(for: .toWatch).map(\.id) == [5, 2])
        #expect(state.links(for: .toWatch, in: 1).map(\.id) == [2])
        #expect(state.links(for: .toWatch, in: 2).map(\.id) == [5])
        #expect(state.links(for: .watched, in: 1).map(\.id) == [4, 1])
        #expect(state.links(for: .sent, in: 3).map(\.id) == [3])
        #expect(state.links(for: .sent, in: 2).isEmpty)
        #expect(state.links(in: 1).map(\.id) == [4, 2, 1])
        #expect(state.links(in: nil).count == 5)
        // The badge stays every chat's To Watch.
        #expect(state.toWatch.map(\.id) == [5, 2])
    }

    @Test func searchMatchesTheChatName() {
        #expect(state.links(for: .all, matching: "film").map(\.id) == [5])
        #expect(state.links(for: .all, in: 1, matching: "film").isEmpty)
    }

    @Test func namesChats() throws {
        #expect(state.title(of: try #require(state.group(1))) == "Everyone")
        #expect(state.title(of: try #require(state.group(2))) == "Film club")
        #expect(state.title(of: try #require(state.group(3))) == "Alex Kim")
        #expect(state.title(of: LinkGroup(id: 9, members: ["user_ME"])) == "Just You")
        #expect(state.title(of: LinkGroup(id: 9, members: ["user_ME", "user_SAM", "user_ALEX"])) == "Sam Lee and Alex Kim")
        #expect(state.title(of: LinkGroup(id: 9, name: "  ", members: ["user_ME", "user_SAM"])) == "Sam Lee")
    }

    @Test func aLinkGoesToItsChatsMembers() throws {
        #expect(state.recipients(in: state.group(2)).map(\.id) == ["user_SAM"])
        #expect(state.recipients(in: state.group(1)).map(\.id) == ["user_SAM", "user_ALEX"])
        let catDance = try #require(state.links.first { $0.id == 5 })
        #expect(state.recipients(of: catDance).isEmpty) // Sam sent it; only Sam and I are in Film club
        let mine = try #require(state.links.first { $0.id == 3 })
        #expect(state.recipients(of: mine).map(\.id) == ["user_ALEX"])
    }

    @Test func addsOnlyPeopleNotInTheChat() throws {
        #expect(state.addable(to: try #require(state.group(2))).map(\.id) == ["user_ALEX"])
        #expect(state.addable(to: try #require(state.group(1))).isEmpty)
        var blocking = state
        blocking.blocked = ["user_ALEX"]
        #expect(blocking.addable(to: try #require(blocking.group(2))).isEmpty)
    }

    @Test func newLinksGoToTheDefaultChat() {
        #expect(state.preferredGroup?.id == 1)
        var left = state.leaving(group: 1)
        #expect(left.preferredGroup?.id == 2)
        left.groups = []
        #expect(left.preferredGroup == nil)
    }

    @Test func leavingDropsTheChatAndItsLinks() {
        let left = state.leaving(group: 2)
        #expect(left.groups.map(\.id) == [1, 3])
        #expect(left.links.map(\.id) == [4, 3, 2, 1])
    }

    @Test func updatingReplacesOrAddsAChat() {
        let renamed = state.updating(LinkGroup(id: 2, name: "Cinema", members: ["user_SAM", "user_ME"]))
        #expect(renamed.groups.map(\.id) == [1, 2, 3])
        #expect(renamed.group(2)?.name == "Cinema")
        let started = state.updating(LinkGroup(id: 4, members: ["user_ME", "user_SAM"]))
        #expect(started.groups.map(\.id) == [1, 2, 3, 4])
    }

    /// One share sheet suggestion per chat, on the thread its notifications use (server/src/push.ts).
    @Test func conversationIDsMatchPushThreads() throws {
        #expect(state.group(1)?.conversationID == "links-inbox")
        #expect(state.group(2)?.conversationID == "links-group-2")
        #expect(Set(state.groups.map(\.conversationID)).count == state.groups.count)
        #expect(state.group(conversationID: "links-inbox")?.id == 1)
        #expect(state.group(conversationID: "links-group-3")?.id == 3)
        #expect(state.group(conversationID: "links-group-99") == nil)
        #expect(state.group(conversationID: nil) == nil)
    }

    @Test func peopleWhoLeftEveryChatAreNotMyPeople() throws {
        var state = state
        state.users.append(LinkUser(id: "user_LEFT", name: "Departed"))
        var link = try #require(state.links.first)
        link.addedBy = "user_LEFT"
        state.links.append(link)

        #expect(!state.otherPeople.map(\.id).contains("user_LEFT"))
        #expect(state.otherPeople.map(\.id) == ["user_SAM", "user_ALEX"])
        #expect(state.addable(to: try #require(state.group(3))).map(\.id) == ["user_SAM"])
        #expect(state.name(of: "user_LEFT") == "Departed")  // their links still say who sent them

        // A server from before chats: everyone it lists.
        state.groups = []
        #expect(state.otherPeople.map(\.id).contains("user_LEFT"))
    }

    @Test func theShareExtensionStartsOnTheSuggestedChat() throws {
        #expect(state.shareGroup(fromSuggestion: false)?.id == 1)
        #expect(state.shareGroup(fromSuggestion: true, conversationID: "links-inbox")?.id == 1)
        #expect(state.shareGroup(fromSuggestion: true, conversationID: "links-group-2")?.id == 2)
        // Left, or never mine: pick one rather than send it to another chat.
        #expect(state.shareGroup(fromSuggestion: true, conversationID: "links-group-99") == nil)
        #expect(state.shareGroup(fromSuggestion: true, conversationID: nil) == nil)

        var one = state
        one.groups = [try #require(state.group(2))]
        #expect(one.shareGroup(fromSuggestion: true, conversationID: "links-group-99")?.id == 2)
        #expect(one.shareGroup(fromSuggestion: false)?.id == 2)

        var none = state
        none.groups = []
        #expect(none.shareGroup(fromSuggestion: true, conversationID: "links-inbox") == nil)
    }
}
