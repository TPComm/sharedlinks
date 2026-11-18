import Foundation
import Testing
@testable import LinksKit

@Suite("Notification comment")
struct NotificationCommentTests {
    static func state(seen: Bool) throws -> InboxState {
        try Fixture.decode(InboxState.self,
            #"{"me":"legacy:Jo","users":[],"links":[\#(Fixture.link(seen: seen ? #"{"legacy:Jo":1794525800}"# : "{}"))]}"#)
    }

    @Test func refreshesSnapshotBeforeReloadingWidgets() async throws {
        try await withTempCache { _ in
            InboxSnapshot.save(try Self.state(seen: false))
            #expect(InboxSnapshot.load()?.links(for: .toWatch).count == 1)
            let fresh = String(decoding: try APIClient.encoder.encode(Self.state(seen: true)), as: UTF8.self)
            let server = StubServer { request in
                request.method == "POST" ? .json(#"{"comment":\#(CommentsTests.comment)}"#) : .json(fresh)
            }
            var reloads = 0
            try await NotificationComment.send("Reply", on: 7, client: server.client()) {
                reloads += 1
                #expect(InboxSnapshot.load()?.links(for: .toWatch).isEmpty == true)
            }
            #expect(reloads == 1)
            #expect(InboxSnapshot.load() == (try Self.state(seen: true)))
            #expect(server.requests.map { $0.url.path() } == ["/api/links/7/comments", "/api/state"])
        }
    }

    @Test func emptyReplyDoesNothing() async throws {
        let server = StubServer(always: .fail(.notConnectedToInternet))
        try await NotificationComment.send(" \n ", on: 7, client: server.client()) {
            Issue.record("Empty reply reloaded widgets")
        }
        #expect(server.requests.isEmpty)
    }

    @Test func failedCommentDoesNotRefresh() async {
        let server = StubServer(always: .json(#"{"error":"No access"}"#, status: 403))
        await #expect(throws: APIError.server("No access")) {
            try await NotificationComment.send("Reply", on: 7, client: server.client()) {
                Issue.record("Failed reply reloaded widgets")
            }
        }
        #expect(server.requests.map(\.method) == ["POST"])
    }

    @Test func failedRefreshKeepsCacheAndDoesNotFailTheSentComment() async throws {
        try await withTempCache { _ in
            let original = try Self.state(seen: false)
            InboxSnapshot.save(original)
            let server = StubServer { request in
                request.method == "POST" ? .json(#"{"comment":\#(CommentsTests.comment)}"#) : .fail(.notConnectedToInternet)
            }
            var reloads = 0
            try await NotificationComment.send("Reply", on: 7, client: server.client()) { reloads += 1 }
            #expect(reloads == 1)
            #expect(InboxSnapshot.load() == original)
            #expect(server.requests.count == 2)
        }
    }
}
