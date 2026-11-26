import Foundation
import Testing
@testable import LinksKit

/// Every call the app makes, and the request server/src/app.ts expects for it.
enum Endpoint: String, CaseIterable, Sendable {
    case exchange, signOut, me, rename, claim, deleteAccount, state, add, seen, unseen, react, unreact, note, delete, thumbnail
    case reportLink, reportPerson, block, unblock
    case exchangeWithInvite, invites, createInvite, createEmailInvite, createChatInvite, revokeInvite, acceptInvite
    case addToGroup, createGroup, renameGroup, addMembers, leaveGroup
    case muteWatched, muteReactions, notifyBoth
    case setPhoto, removePhoto
    case nudge, nudgeEveryone, nudgeEmpty
    case chatLink, createChatLink, resetChatLink, turnOffChatLink

    var method: String {
        switch self {
        case .me, .state, .thumbnail, .invites, .chatLink: "GET"
        case .turnOffChatLink: "DELETE"
        case .setPhoto: "PUT"
        case .rename, .note, .renameGroup, .muteWatched, .muteReactions, .notifyBoth: "PATCH"
        case .delete, .deleteAccount, .unblock, .revokeInvite, .leaveGroup, .removePhoto: "DELETE"
        default: "POST"
        }
    }

    var path: String {
        switch self {
        case .exchange, .exchangeWithInvite: "/api/auth/token"
        case .signOut: "/api/auth/logout"
        case .me, .rename, .deleteAccount, .muteWatched, .muteReactions, .notifyBoth: "/api/me"
        case .claim: "/api/me/claim"
        case .setPhoto, .removePhoto: "/api/me/photo"
        case .state: "/api/state"
        case .add, .addToGroup: "/api/links"
        case .createGroup: "/api/groups"
        case .renameGroup, .leaveGroup: "/api/groups/5"
        case .addMembers: "/api/groups/5/members"
        case .seen, .unseen: "/api/links/7/seen"
        case .nudge, .nudgeEveryone, .nudgeEmpty: "/api/links/7/nudge"
        case .react, .unreact: "/api/links/7/react"
        case .note, .delete: "/api/links/7"
        case .thumbnail: "/thumbs/7"
        case .reportLink, .reportPerson: "/api/reports"
        case .block: "/api/blocks"
        case .unblock: "/api/blocks/user_01SAM"
        case .invites, .createInvite, .createEmailInvite, .createChatInvite: "/api/invites"
        case .revokeInvite: "/api/invites/3"
        case .acceptInvite: "/api/invites/accept"
        case .chatLink, .createChatLink, .resetChatLink, .turnOffChatLink: "/api/groups/5/link"
        }
    }

    /// The JSON body, keys sorted; nil when the request has none.
    var body: String? {
        switch self {
        case .chatLink, .turnOffChatLink: nil
        case .createChatLink: #"{}"#
        case .resetChatLink: #"{"reset":true}"#
        case .exchange: #"{"code":"code_abc","code_verifier":"ver_xyz"}"#
        case .exchangeWithInvite: #"{"code":"code_abc","code_verifier":"ver_xyz","invite":"inv_tok"}"#
        case .createInvite: #"{}"#
        case .acceptInvite: #"{"token":"inv_tok"}"#
        case .createEmailInvite: #"{"email":"pal@x.com"}"#
        case .createChatInvite: #"{"email":"pal@x.com","group_id":5}"#
        case .rename: #"{"name":"Sam L"}"#
        case .muteWatched: #"{"notifications":{"watched":false}}"#
        case .muteReactions: #"{"notifications":{"reactions":false}}"#
        case .notifyBoth: #"{"notifications":{"reactions":true,"watched":true}}"#
        case .claim: #"{"id":"legacy:Jo"}"#
        case .add: #"{"note":"for you","url":"lol https://vm.tiktok.com/ZMabc/"}"#
        case .addToGroup: #"{"group_id":5,"note":"","url":"https://vm.tiktok.com/ZMabc/"}"#
        case .createGroup: #"{"members":["user_01JO"],"name":"Film club"}"#
        case .renameGroup: #"{"name":"Cinema"}"#
        case .addMembers: #"{"members":["user_01AL","user_01BO"]}"#
        case .seen: #"{"seen":true}"#
        case .nudge: #"{"people":["user_01JO"]}"#
        case .nudgeEveryone: #"{}"#
        case .nudgeEmpty: #"{"people":[]}"#
        case .unseen: #"{"seen":false}"#
        case .react: #"{"emoji":"🔥"}"#
        case .unreact: #"{"emoji":null}"#
        case .note: #"{"note":"new note"}"#
        case .reportLink: #"{"link_id":7,"reason":"offensive"}"#
        case .reportPerson: #"{"reason":"harassment","user_id":"user_01SAM"}"#
        case .block: #"{"user_id":"user_01SAM"}"#
        case .signOut, .me, .deleteAccount, .state, .delete, .thumbnail, .unblock, .invites, .revokeInvite, .leaveGroup,
             .setPhoto, .removePhoto: nil
        }
    }

    /// The photo PUT /api/me/photo sends as is, not as JSON.
    var upload: Data? { self == .setPhoto ? Data([0xFF, 0xD8, 0xFF]) : nil }

    var reply: Reply {
        switch self {
        case .chatLink, .createChatLink, .resetChatLink:
            .json(#"{"link":{"url":"https://links.test/invite/abc","created_at":1700000000.5,"created_by":"user_01SAM"}}"#, status: self == .resetChatLink ? 201 : 200)
        case .turnOffChatLink: .json(#"{"link":null}"#)
        case .exchange, .exchangeWithInvite: .json(#"{"token": "tok_new", "user": \#(Fixture.sam), "claimable": []}"#)
        case .invites, .revokeInvite: .json(#"{"invites": [{"id": 3, "email": null, "created_at": 1700000000, "expires_at": 1700604800}]}"#)
        case .createInvite, .createEmailInvite, .createChatInvite:
            .json(#"{"invite": {"id": 4, "email": "pal@x.com", "created_at": 1700000000, "expires_at": 1700604800, "url": "https://links.test/invite/abc"}}"#, status: 201)
        case .signOut, .delete, .deleteAccount, .leaveGroup: .json(#"{"ok": true}"#)
        case .createGroup: .json(#"{"group": \#(Fixture.group())}"#, status: 201)
        case .renameGroup, .addMembers, .acceptInvite: .json(#"{"group": \#(Fixture.group())}"#)
        case .me, .rename, .claim, .setPhoto, .removePhoto: .json(Fixture.me)
        case .muteWatched, .muteReactions, .notifyBoth: .json(Fixture.meWithNotifications())
        case .state: .json(#"{"me": "user_01SAM", "users": [\#(Fixture.sam)], "links": [\#(Fixture.link())]}"#)
        case .add, .addToGroup: .json(#"{"link": \#(Fixture.link()), "duplicate": false}"#, status: 201)
        case .seen, .unseen, .react, .unreact, .note, .nudge, .nudgeEveryone, .nudgeEmpty: .json(#"{"link": \#(Fixture.link())}"#)
        case .thumbnail: .http(status: 200, body: Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")
        case .reportLink, .reportPerson: .json(#"{"ok": true}"#, status: 201)
        case .block: .json(#"{"blocked": ["user_01SAM"]}"#)
        case .unblock: .json(#"{"blocked": []}"#)
        }
    }

    func call(_ client: APIClient) async throws {
        let link = try Fixture.decode(SharedLink.self, Fixture.link())
        switch self {
        case .exchange: _ = try await client.exchange(code: "code_abc", verifier: "ver_xyz")
        case .signOut: await client.signOut()
        case .me: _ = try await client.me()
        case .rename: _ = try await client.rename(to: "Sam L")
        case .muteWatched: _ = try await client.setNotifications(watched: false)
        case .muteReactions: _ = try await client.setNotifications(reactions: false)
        case .notifyBoth: _ = try await client.setNotifications(watched: true, reactions: true)
        case .claim: _ = try await client.claim("legacy:Jo")
        case .deleteAccount: try await client.deleteAccount()
        case .state: _ = try await client.state()
        case .add: _ = try await client.add("lol https://vm.tiktok.com/ZMabc/", note: "for you")
        case .seen: _ = try await client.setSeen(7, true)
        case .nudge: #expect(try await client.nudge(7, people: ["user_01JO"]).id == 7)
        case .nudgeEveryone: _ = try await client.nudge(7)
        case .nudgeEmpty: _ = try await client.nudge(7, people: [])
        case .unseen: _ = try await client.setSeen(7, false)
        case .react: _ = try await client.react(7, "🔥")
        case .unreact: _ = try await client.react(7, nil)
        case .note: _ = try await client.setNote(7, "new note")
        case .delete: try await client.delete(7)
        case .thumbnail: _ = try await client.thumbnail(link)
        case .reportLink: try await client.report(link: 7, reason: .offensive)
        case .reportPerson: try await client.report(person: "user_01SAM", reason: .harassment)
        case .block: #expect(try await client.block("user_01SAM") == ["user_01SAM"])
        case .unblock: #expect(try await client.unblock("user_01SAM") == [])
        case .exchangeWithInvite: _ = try await client.exchange(code: "code_abc", verifier: "ver_xyz", invite: "inv_tok")
        case .invites:
            let invites = try await client.invites()
            #expect(invites.map(\.id) == [3])
            #expect(invites.first?.expiresAt == Date(timeIntervalSince1970: 1_700_604_800))
            #expect(invites.first?.url == nil)
        case .createInvite: #expect(try await client.createInvite().url == URL(string: "https://links.test/invite/abc"))
        case .createEmailInvite: #expect(try await client.createInvite(email: "pal@x.com").email == "pal@x.com")
        case .createChatInvite: _ = try await client.createInvite(email: "pal@x.com", groupID: 5)
        case .revokeInvite: #expect(try await client.revokeInvite(3).map(\.id) == [3])
        case .acceptInvite: #expect(try await client.acceptInvite("inv_tok")?.id == 5)
        case .chatLink:
            let link = try await client.chatInviteLink(groupID: 5)
            #expect(link?.url == URL(string: "https://links.test/invite/abc"))
            #expect(link?.createdAt == Date(timeIntervalSince1970: 1_700_000_000.5))
            #expect(link?.createdBy == "user_01SAM")
        case .createChatLink: #expect(try await client.createChatInviteLink(groupID: 5).url == URL(string: "https://links.test/invite/abc"))
        case .resetChatLink: #expect(try await client.createChatInviteLink(groupID: 5, reset: true).url == URL(string: "https://links.test/invite/abc"))
        case .turnOffChatLink: try await client.turnOffChatInviteLink(groupID: 5)
        case .addToGroup:
            #expect(try await client.add("https://vm.tiktok.com/ZMabc/", groupID: 5).link.groupID == 1)
        case .createGroup:
            let group = try await client.createGroup(name: "Film club", members: ["user_01JO"])
            #expect(group.id == 5 && group.members == ["user_01SAM", "user_01JO"] && !group.isDefault)
        case .renameGroup: #expect(try await client.renameGroup(5, to: "Cinema").name == "Film club")
        case .addMembers: _ = try await client.addMembers(["user_01AL", "user_01BO"], to: 5)
        case .leaveGroup: try await client.leaveGroup(5)
        case .setPhoto: _ = try await client.setPhoto(Data([0xFF, 0xD8, 0xFF]))
        case .removePhoto: _ = try await client.removePhoto()
        }
    }
}

@Suite("APIClient requests")
struct APIClientRequestTests {
    @Test func catchUpPatchCanSetClearOrOmit() async throws {
        let server = StubServer(always: .json(Fixture.meWithNotifications()))
        let client = server.client()
        _ = try await client.setNotifications(catchup: .some(CatchUp(time: "18:00", timeZone: "Australia/Sydney")))
        #expect(server.requests.last?.canonicalJSON == #"{"notifications":{"catchup":{"time":"18:00","timeZone":"Australia/Sydney"}}}"#)
        _ = try await client.setNotifications(catchup: .some(nil))
        #expect(server.requests.last?.canonicalJSON == #"{"notifications":{"catchup":null}}"#)
        _ = try await client.setNotifications(watched: false)
        #expect(server.requests.last?.canonicalJSON == #"{"notifications":{"watched":false}}"#)
    }

    @Test func catchUpDecodesWithOldAndNewSettings() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(NotificationSettings.self, from: Data(#"{"watched":true,"reactions":true}"#.utf8))
        #expect(old.catchup == nil)
        let new = try decoder.decode(NotificationSettings.self, from: Data(#"{"watched":true,"reactions":true,"catchup":{"time":"18:00","timeZone":"UTC"}}"#.utf8))
        #expect(new.catchup == CatchUp(time: "18:00", timeZone: "UTC"))
    }

    @Test(arguments: Endpoint.allCases)
    func sendsWhatTheServerExpects(_ endpoint: Endpoint) async throws {
        let server = StubServer(always: endpoint.reply)
        try await endpoint.call(server.client())

        let request = try #require(server.requests.only)
        #expect(request.method == endpoint.method)
        #expect(request.url.path() == endpoint.path)
        #expect(request.url.query() == nil)
        #expect(request.header("Authorization") == "Bearer tok_123")
        #expect(request.header("Accept") == "application/json")
        if let body = endpoint.body {
            #expect(request.header("Content-Type") == "application/json")
            #expect(request.canonicalJSON == body)
        } else if let upload = endpoint.upload {
            #expect(request.header("Content-Type") == "image/jpeg")
            #expect(request.body == upload)
        } else {
            #expect(request.body == nil || request.body?.isEmpty == true)
            #expect(request.header("Content-Type") == nil)
        }
    }

    @Test func signedOutRequestsCarryNoAuthorization() async throws {
        let server = StubServer(always: Endpoint.exchange.reply)
        _ = try await server.client(token: nil).exchange(code: "c", verifier: "v")
        #expect(server.requests.only?.header("Authorization") == nil)
    }

    @Test func keepsAPathPrefixOnTheServerURL() async throws {
        // e.g. the API behind a reverse proxy at https://host/links
        let link = try Fixture.decode(SharedLink.self, Fixture.link(id: 3))
        for path in ["/links", "/links/"] {
            let server = StubServer(path: path) { request in
                request.url.path().hasSuffix("/state") ? Endpoint.state.reply : .http(status: 200, body: Data([1]), contentType: "image/jpeg")
            }
            _ = try await server.client().state()
            _ = try await server.client().thumbnail(link)
            #expect(server.requests.map { $0.url.path() } == ["/links/api/state", "/links/thumbs/3"])
        }
    }

    @Test func requestsTimeOutRatherThanHang() {
        let client = APIClient(baseURL: URL(string: "https://links.test")!, token: nil)
        #expect(client.request("GET", "api/state").timeoutInterval == 20)
    }
}

@Suite("APIClient responses")
struct APIClientResponseTests {
    @Test(arguments: [true, false]) func inviteKindIsAvailableWithoutSigningIn(_ open: Bool) async throws {
        let server = StubServer(always: .json(open ? #"{"open":true}"# : #"{"open":false}"#))
        #expect(try await server.client(token: nil).inviteIsOpen("inv_tok") == open)
        let request = try #require(server.requests.only)
        #expect(request.method == "GET")
        #expect(request.url.path() == "/api/invites/kind/inv_tok")
        #expect(request.header("Authorization") == nil)
    }

    @Test func inviteKindLookupPropagatesFailures() async {
        let server = StubServer(always: .json(#"{"error":"Try again."}"#, status: 503))
        await #expect(throws: APIError.server("Try again.")) {
            try await server.client(token: nil).inviteIsOpen("inv_tok")
        }
    }

    @Test func exchangeReturnsTheSessionAndUser() async throws {
        let server = StubServer(always: .json(#"{"token": "tok_new", "user": \#(Fixture.sam), "claimable": [\#(Fixture.jo)]}"#))
        let result = try await server.client(token: nil).exchange(code: "c", verifier: "v")
        #expect(result.token == "tok_new")
        #expect(result.user.id == "user_01SAM")
        #expect(result.user.name == "Sam Lee")
        #expect(result.user.email == "sam@example.com")
        #expect(result.user.avatar == URL(string: "https://example.com/sam.png"))
        #expect(result.claimable.map(\.id) == ["legacy:Jo"])
        #expect(result.claimable.first?.isLegacy == true)
        #expect(result.groupID == nil)
    }

    @Test func exchangeSaysWhichChatAnInviteTookThemTo() async throws {
        let server = StubServer(always: .json(#"{"token": "tok_new", "user": \#(Fixture.sam), "claimable": [], "group_id": 5}"#))
        #expect(try await server.client(token: nil).exchange(code: "c", verifier: "v", invite: "inv_tok").groupID == 5)
    }

    @Test func acceptingAnInviteToNoChatReturnsNil() async throws {
        let server = StubServer(always: .json(#"{"group": null}"#))
        #expect(try await server.client().acceptInvite("inv_tok") == nil)
    }

    @Test func chatWithoutInviteLinkReturnsNil() async throws {
        let server = StubServer(always: .json(#"{"link":null}"#))
        #expect(try await server.client().chatInviteLink(groupID: 5) == nil)
    }

    @Test func accountCallsReturnMe() async throws {
        let server = StubServer(always: .json(Fixture.me))
        let client = server.client()
        for response in [try await client.me(), try await client.rename(to: "Sam L"), try await client.claim("legacy:Jo")] {
            #expect(response.user.name == "Sam Lee")
            #expect(response.claimable.map(\.name) == ["Jo"])
        }
    }

    @Test func notificationSettingsComeWithMe() async throws {
        let server = StubServer(always: .json(Fixture.meWithNotifications(watched: false, reactions: true)))
        let client = server.client()
        for response in [try await client.me(), try await client.setNotifications(watched: false)] {
            #expect(response.notifications == NotificationSettings(watched: false, reactions: true))
            #expect(response.user.name == "Sam Lee")
        }
    }

    @Test func olderServersHaveNoNotificationSettings() async throws {
        let server = StubServer(always: .json(Fixture.me))
        #expect(try await server.client().me().notifications == nil)
    }

    @Test func stateDecodes() async throws {
        let server = StubServer(always: Endpoint.state.reply)
        let state = try await server.client().state()
        #expect(state.me == "user_01SAM")
        #expect(state.users.map(\.id) == ["user_01SAM"])
        #expect(state.links.map(\.id) == [7])
        let link = try #require(state.links.first)
        #expect(link.platform == .youtube)
        #expect(link.addedAt == Date(timeIntervalSince1970: 1794525713.5))
    }

    @Test(arguments: [(201, false), (200, true)])
    func addReportsDuplicates(status: Int, duplicate: Bool) async throws {
        let server = StubServer(always: .json(#"{"link": \#(Fixture.link(id: 9)), "duplicate": \#(duplicate)}"#, status: status))
        let result = try await server.client().add("https://youtu.be/abc")
        #expect(result.link.id == 9)
        #expect(result.duplicate == duplicate)
        #expect(server.requests.only?.canonicalJSON == #"{"note":"","url":"https://youtu.be/abc"}"#)
    }

    @Test func linkCallsUnwrapTheEnvelope() async throws {
        let updated = Fixture.link(note: "edited", seen: #"{"user_01ME": 1794525800}"#, reactions: #"{"user_01ME": "😂"}"#)
        let server = StubServer(always: .json(#"{"link": \#(updated)}"#))
        let client = server.client()
        for link in [try await client.setSeen(7, true), try await client.react(7, "😂"), try await client.setNote(7, "edited")] {
            #expect(link.id == 7)
            #expect(link.note == "edited")
            #expect(link.seen["user_01ME"] == Date(timeIntervalSince1970: 1794525800))
            #expect(link.reactions == ["user_01ME": "😂"])
        }
    }

    @Test func thumbnailReturnsTheBytesAsIs() async throws {
        let png = TestImage.png(width: 4, height: 4)
        let server = StubServer(always: .http(status: 200, body: png, contentType: "image/png"))
        let link = try Fixture.decode(SharedLink.self, Fixture.link())
        let data = try await server.client().thumbnail(link)
        #expect(data == png)
    }

    @Test func linkWithoutThumbnailDoesNotHitTheServer() async throws {
        let server = StubServer(always: .json("{}"))
        let link = SharedLink(id: 1, url: URL(string: "https://example.com")!, platform: .web, addedBy: "u")
        await #expect(throws: APIError.server("No thumbnail.")) { try await server.client().thumbnail(link) }
        #expect(server.requests.isEmpty)
    }
}

@Suite("APIClient errors")
struct APIClientErrorTests {
    @Test func chatLinkFailuresReachTheCaller() async {
        let server = StubServer(always: .json(#"{"error":"That chat isn't there anymore."}"#, status: 404))
        let error = APIError.server("That chat isn't there anymore.")
        await #expect(throws: error) { try await server.client().chatInviteLink(groupID: 5) }
        await #expect(throws: error) { try await server.client().createChatInviteLink(groupID: 5) }
        await #expect(throws: error) { try await server.client().createChatInviteLink(groupID: 5, reset: true) }
        await #expect(throws: error) { try await server.client().turnOffChatInviteLink(groupID: 5) }
    }

    @Test func unauthorizedMeansSignedOut() async {
        let server = StubServer(always: .json(#"{"error": "Sign in to continue."}"#, status: 401))
        await #expect(throws: APIError.signedOut) { try await server.client().state() }
        await #expect(throws: APIError.signedOut) { try await server.client().delete(1) }
        await #expect(throws: APIError.signedOut) { try await server.client().deleteAccount() }
    }

    @Test func nudgeCooldownMessageReachesTheUser() async {
        let message = "You've already nudged them. Try again after 24 hours."
        let server = StubServer(always: .json(#"{"error":"\#(message)"}"#, status: 429))
        await #expect(throws: APIError.server(message)) { try await server.client().nudge(7, people: ["user_01JO"]) }
    }

    @Test(arguments: [
        (400, #"{"error": "That doesn't look like a link."}"#, "That doesn't look like a link."),
        (404, #"{"error": "That link was deleted."}"#, "That link was deleted."),
        (500, #"{"error": "Something went wrong."}"#, "Something went wrong."),
        (403, #"{"error": "Not allowed", "extra": 1}"#, "Not allowed"),
    ])
    func serverMessagesReachTheUser(status: Int, body: String, message: String) async {
        let server = StubServer(always: .json(body, status: status))
        await #expect(throws: APIError.server(message)) { try await server.client().add("https://example.com") }
    }

    @Test(arguments: [
        (502, Reply.text("<html>Bad Gateway</html>", status: 502)),
        (500, Reply.json(#"{"message": "nope"}"#, status: 500)),
        (400, Reply.json(#"{"error": 42}"#, status: 400)),
        (503, Reply.http(status: 503, body: Data(), contentType: "text/plain")),
    ])
    func unreadableErrorsGetAGenericMessage(status: Int, reply: Reply) async {
        let server = StubServer(always: reply)
        await #expect(throws: APIError.server("Something went wrong (\(status)).")) { try await server.client().me() }
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotConnectToHost, .networkConnectionLost])
    func transportFailuresAreOffline(_ code: URLError.Code) async {
        let server = StubServer(always: .fail(code))
        await #expect(throws: APIError.offline) { try await server.client().state() }
    }

    @Test func cancellationIsNotReportedAsOffline() async {
        // Cancelled refreshes (pull-to-refresh, a view going away) must not show "Can't reach Links".
        let server = StubServer(always: .fail(.cancelled))
        let error = await #expect(throws: URLError.self) { try await server.client().state() }
        #expect(error?.code == .cancelled)
    }

    @Test func nonHTTPResponseIsOffline() async {
        let server = StubServer(always: .notHTTP)
        await #expect(throws: APIError.offline) { try await server.client().me() }
    }

    @Test func malformedSuccessBodyIsADecodingError() async {
        let server = StubServer(always: .json(#"{"me": "u1", "users": "nope"}"#))
        await #expect(throws: DecodingError.self) { try await server.client().state() }
    }

    @Test(arguments: [Reply.json(#"{"error": "Something went wrong."}"#, status: 500), .fail(.notConnectedToInternet), .json("not json")])
    func signOutNeverThrows(_ reply: Reply) async {
        let server = StubServer(always: reply)
        await server.client().signOut()
        #expect(server.requests.only?.url.path() == "/api/auth/logout")
    }

    @Test func messagesForTheUser() {
        #expect(APIError.signedOut.localizedDescription == "Sign in to Links to continue.")
        #expect(APIError.offline.localizedDescription == "Can't reach Links right now.")
        #expect(APIError.server("That link was deleted.").localizedDescription == "That link was deleted.")
    }
}

extension Array {
    /// The single element, or nil if there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
