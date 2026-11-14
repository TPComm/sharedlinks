import Foundation
import Testing
@testable import LinksKit

/// Every call the app makes, and the request server/src/app.ts expects for it.
enum Endpoint: String, CaseIterable, Sendable {
    case exchange, signOut, me, rename, claim, deleteAccount, state, add, seen, unseen, react, unreact, note, delete, thumbnail

    var method: String {
        switch self {
        case .me, .state, .thumbnail: "GET"
        case .rename, .note: "PATCH"
        case .delete, .deleteAccount: "DELETE"
        default: "POST"
        }
    }

    var path: String {
        switch self {
        case .exchange: "/api/auth/token"
        case .signOut: "/api/auth/logout"
        case .me, .rename, .deleteAccount: "/api/me"
        case .claim: "/api/me/claim"
        case .state: "/api/state"
        case .add: "/api/links"
        case .seen, .unseen: "/api/links/7/seen"
        case .react, .unreact: "/api/links/7/react"
        case .note, .delete: "/api/links/7"
        case .thumbnail: "/thumbs/7"
        }
    }

    /// The JSON body, keys sorted; nil when the request has none.
    var body: String? {
        switch self {
        case .exchange: #"{"code":"code_abc","code_verifier":"ver_xyz"}"#
        case .rename: #"{"name":"Sam L"}"#
        case .claim: #"{"id":"legacy:Jo"}"#
        case .add: #"{"note":"for you","url":"lol https://vm.tiktok.com/ZMabc/"}"#
        case .seen: #"{"seen":true}"#
        case .unseen: #"{"seen":false}"#
        case .react: #"{"emoji":"🔥"}"#
        case .unreact: #"{"emoji":null}"#
        case .note: #"{"note":"new note"}"#
        case .signOut, .me, .deleteAccount, .state, .delete, .thumbnail: nil
        }
    }

    var reply: Reply {
        switch self {
        case .exchange: .json(#"{"token": "tok_new", "user": \#(Fixture.sam), "claimable": []}"#)
        case .signOut, .delete, .deleteAccount: .json(#"{"ok": true}"#)
        case .me, .rename, .claim: .json(Fixture.me)
        case .state: .json(#"{"me": "user_01SAM", "users": [\#(Fixture.sam)], "links": [\#(Fixture.link())]}"#)
        case .add: .json(#"{"link": \#(Fixture.link()), "duplicate": false}"#, status: 201)
        case .seen, .unseen, .react, .unreact, .note: .json(#"{"link": \#(Fixture.link())}"#)
        case .thumbnail: .http(status: 200, body: Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")
        }
    }

    func call(_ client: APIClient) async throws {
        let link = try Fixture.decode(SharedLink.self, Fixture.link())
        switch self {
        case .exchange: _ = try await client.exchange(code: "code_abc", verifier: "ver_xyz")
        case .signOut: await client.signOut()
        case .me: _ = try await client.me()
        case .rename: _ = try await client.rename(to: "Sam L")
        case .claim: _ = try await client.claim("legacy:Jo")
        case .deleteAccount: try await client.deleteAccount()
        case .state: _ = try await client.state()
        case .add: _ = try await client.add("lol https://vm.tiktok.com/ZMabc/", note: "for you")
        case .seen: _ = try await client.setSeen(7, true)
        case .unseen: _ = try await client.setSeen(7, false)
        case .react: _ = try await client.react(7, "🔥")
        case .unreact: _ = try await client.react(7, nil)
        case .note: _ = try await client.setNote(7, "new note")
        case .delete: try await client.delete(7)
        case .thumbnail: _ = try await client.thumbnail(link)
        }
    }
}

@Suite("APIClient requests")
struct APIClientRequestTests {
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
    }

    @Test func accountCallsReturnMe() async throws {
        let server = StubServer(always: .json(Fixture.me))
        let client = server.client()
        for response in [try await client.me(), try await client.rename(to: "Sam L"), try await client.claim("legacy:Jo")] {
            #expect(response.user.name == "Sam Lee")
            #expect(response.claimable.map(\.name) == ["Jo"])
        }
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
    @Test func unauthorizedMeansSignedOut() async {
        let server = StubServer(always: .json(#"{"error": "Sign in to continue."}"#, status: 401))
        await #expect(throws: APIError.signedOut) { try await server.client().state() }
        await #expect(throws: APIError.signedOut) { try await server.client().delete(1) }
        await #expect(throws: APIError.signedOut) { try await server.client().deleteAccount() }
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
