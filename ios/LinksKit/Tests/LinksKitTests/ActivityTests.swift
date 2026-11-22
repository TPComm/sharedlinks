import Foundation
import Testing
@testable import LinksKit

struct ActivityTests {
    private static let page = #"{"items":[{"kind":"comment","link_id":7,"person":"friend","at":30,"comment_id":42,"snippet":"Hello"},{"kind":"reaction","link_id":7,"person":"friend","at":20,"emoji":"😂"},{"kind":"watched","link_id":7,"person":"friend","at":10}],"has_more":true}"#

    @Test func decodesKindsAndReadPositions() throws {
        let page = try APIClient.decoder.decode(ActivityPage.self, from: Data(Self.page.utf8))
        #expect(page.hasMore)
        #expect(page.items.map(\.kind) == [.comment, .reaction, .watched])
        #expect(Set(page.items.map(\.id)).count == 3)
        let comment = page.items[0]
        #expect(comment.linkID == 7 && comment.commentID == 42 && comment.snippet == "Hello")
        #expect(comment.at == Date(timeIntervalSince1970: 30))
        #expect(page.items[1].emoji == "😂" && page.items[2].commentID == nil)
        var reads = CommentReadState()
        let server = URL(string: "https://links.test")!
        #expect(reads.hasUnread(comment, person: "me", server: server))
        #expect(!reads.hasUnread(comment, person: "friend", server: server))
        #expect(!reads.hasUnread(page.items[1], person: "me", server: server))
        reads.markRead(7, through: comment.at, person: "me", server: server)
        #expect(!reads.hasUnread(comment, person: "me", server: server))
        let encoded = try APIClient.encoder.encode(page)
        #expect(try APIClient.decoder.decode(ActivityPage.self, from: encoded).items == page.items)
    }

    @Test func buildsActivityRequestsAndHandlesEmptyPages() async throws {
        let server = StubServer(always: .json(#"{"items":[],"has_more":false}"#))
        let client = server.client()
        let empty = try await client.activity()
        #expect(empty.items.isEmpty && !empty.hasMore)
        _ = try await client.activity(before: Date(timeIntervalSince1970: 123.5), limit: 10)
        let requests = server.requests
        #expect(requests.allSatisfy { $0.method == "GET" && $0.url.path() == "/api/activity" && $0.header("Authorization") == "Bearer tok_123" })
        #expect(URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "limit", value: "50")])
        #expect(URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "before", value: "123.5")])
    }

    @Test func propagatesErrors() async throws {
        let server = StubServer(always: .json(#"{"error":"No access"}"#, status: 403))
        await #expect(throws: APIError.server("No access")) { try await server.client().activity() }
    }
}
