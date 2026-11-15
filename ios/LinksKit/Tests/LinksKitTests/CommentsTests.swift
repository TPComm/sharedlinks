import Foundation
import Testing
@testable import LinksKit

@Suite("Comments")
struct CommentsTests {
    static let comment = #"{"id":42,"link_id":7,"person":"friend","body":"Watch that ending!","created_at":1794525800.25,"edited_at":null}"#

    @Test func validatesTheSameUnicodeCodePointLimitAsTheServer() {
        #expect(!LinkComment.isValidBody(" \n\t "))
        #expect(LinkComment.isValidBody(" \nHello\n "))
        #expect(LinkComment.isValidBody(String(repeating: "🙂", count: 1_000)))
        #expect(!LinkComment.isValidBody(String(repeating: "🙂", count: 1_001)))
        #expect(!LinkComment.isValidBody(String(repeating: "e\u{301}", count: 501)))
    }

    @Test func decodesCommentsAndEdits() throws {
        let comment = try Fixture.decode(LinkComment.self, Self.comment)
        #expect(comment.id == 42 && comment.linkID == 7 && comment.person == "friend")
        #expect(comment.body == "Watch that ending!")
        #expect(comment.createdAt == Date(timeIntervalSince1970: 1794525800.25))
        #expect(comment.editedAt == nil)
        let edited = try Fixture.decode(LinkComment.self, Self.comment.replacingOccurrences(of: "null", with: "1794525900"))
        #expect(edited.editedAt == Date(timeIntervalSince1970: 1794525900))
        #expect(try APIClient.decoder.decode(LinkComment.self, from: APIClient.encoder.encode(edited)) == edited)
    }

    @Test func decodesActivityAndKeepsOldCachesCompatible() throws {
        let old = try Fixture.decode(SharedLink.self, Fixture.link())
        #expect(old.commentCount == 0 && old.lastComment == nil)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(Fixture.link().utf8)) as? [String: Any])
        json["comment_count"] = 2
        json["last_comment"] = ["person": "friend", "snippet": "Ending!", "at": 1794525800] as [String: Any]
        let link = try APIClient.decoder.decode(SharedLink.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(link.commentCount == 2 && link.lastComment?.snippet == "Ending!")
        #expect(try APIClient.decoder.decode(SharedLink.self, from: APIClient.encoder.encode(link)) == link)
    }

    @Test func unreadPositionsAreMonotonicAndAccountAndServerScoped() throws {
        let server = URL(string: "https://links.test")!
        let otherServer = URL(string: "https://other.test")!
        var link = try Fixture.decode(SharedLink.self, Fixture.link())
        link.commentCount = 1
        let at = Date(timeIntervalSince1970: 1_794_525_800)
        link.lastComment = CommentActivity(person: "friend", snippet: "Hello", at: at)
        var reads = CommentReadState()
        #expect(reads.hasUnread(link, person: "me", server: server))
        #expect(!reads.hasUnread(link, person: "friend", server: server))
        reads.markRead(link.id, through: at, person: "me", server: server)
        reads.markRead(link.id, through: at.addingTimeInterval(-10), person: "me", server: server)
        #expect(!reads.hasUnread(link, person: "me", server: server))
        #expect(reads.hasUnread(link, person: "other", server: server))
        #expect(reads.hasUnread(link, person: "me", server: otherServer))
        link.lastComment = CommentActivity(person: "friend", snippet: "New", at: at.addingTimeInterval(1))
        #expect(reads.hasUnread(link, person: "me", server: server))
        link.commentCount = 0
        #expect(!reads.hasUnread(link, person: "me", server: server))
    }

    @Test func readPositionsSurviveRelaunchAndCorruptStorage() throws {
        let suite = "comments-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = URL(string: "https://links.test")!
        var link = try Fixture.decode(SharedLink.self, Fixture.link())
        link.commentCount = 1
        link.lastComment = CommentActivity(person: "friend", snippet: "Hello", at: .now)
        var reads = CommentReadState.load(defaults: defaults)
        #expect(reads.hasUnread(link, person: "me", server: server))
        reads.markRead(link.id, through: .distantFuture, person: "me", server: server)
        reads.save(defaults: defaults)
        #expect(!CommentReadState.load(defaults: defaults).hasUnread(link, person: "me", server: server))
        defaults.set(Data("broken".utf8), forKey: "commentReadState")
        #expect(CommentReadState.load(defaults: defaults).hasUnread(link, person: "me", server: server))
    }

    @Test func sendsCommentCRUDRequests() async throws {
        let server = StubServer { request in
            if request.method == "DELETE" { return .json(#"{"ok":true}"#) }
            if request.method == "GET" { return .json(#"{"comments":[\#(Self.comment)]}"#) }
            return .json(#"{"comment":\#(Self.comment)}"#)
        }
        let client = server.client()
        #expect(try await client.comments(7).map(\.id) == [42])
        #expect(try await client.addComment(7, body: "First!").id == 42)
        #expect(try await client.editComment(42, body: "Edited").linkID == 7)
        try await client.deleteComment(42)
        #expect(server.requests.map(\.method) == ["GET", "POST", "PATCH", "DELETE"])
        #expect(server.requests.map { $0.url.path() } == ["/api/links/7/comments", "/api/links/7/comments", "/api/comments/42", "/api/comments/42"])
        #expect(server.requests[1].canonicalJSON == #"{"body":"First!"}"#)
        #expect(server.requests[2].canonicalJSON == #"{"body":"Edited"}"#)
        #expect(server.requests.allSatisfy { $0.header("Authorization") == "Bearer tok_123" })
    }

    @Test func commentErrorsAreNotTreatedAsEmptyThreads() async throws {
        let server = StubServer(always: .json(#"{"error":"No access"}"#, status: 403))
        await #expect(throws: APIError.server("No access")) { try await server.client().comments(7) }
    }

    @Test func reportsOnlyTheSelectedComment() async throws {
        let server = StubServer(always: .json(#"{"ok":true}"#, status: 201))
        try await server.client().report(comment: 42, reason: .harassment)
        let request = try #require(server.requests.only)
        #expect(request.method == "POST" && request.url.path() == "/api/reports")
        #expect(request.canonicalJSON == #"{"comment_id":42,"reason":"harassment"}"#)
    }
}
