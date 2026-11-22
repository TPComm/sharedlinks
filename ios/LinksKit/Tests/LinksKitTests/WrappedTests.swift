import Foundation
import Testing
@testable import LinksKit

struct WrappedTests {
    @Test func requestsRangeAndDecodesHighlights() async throws {
        let server = StubServer(always: .json(#"{"start":100,"end":200,"received":4,"sent":2,"watched":3,"top_sender":{"id":"friend","name":"Friend","count":4},"top_platform":{"platform":"youtube","count":3},"most_reacted":{"id":7,"url":"https://youtube.com/watch?v=1","title":"A favorite","platform":"youtube","added_by":"friend","sender_name":"Friend","thumb":"/thumbs/7","reactions":2}}"#))
        let result = try await server.client().wrapped(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200), groupID: 7)
        #expect(result.watchRate == 0.75)
        #expect(result.topSender?.name == "Friend" && result.topPlatform?.count == 3)
        #expect(result.mostReacted?.id == 7 && result.mostReacted?.reactions == 2 && result.mostReacted?.title == "A favorite")
        #expect(result.start == Date(timeIntervalSince1970: 100))
        let request = try #require(server.requests.only)
        #expect(request.method == "GET" && request.url.path() == "/api/wrapped")
        #expect(request.url.query() == "start=100&end=200&group_id=7")
        #expect(request.header("Authorization") == "Bearer tok_123")
    }

    @Test func decodesEmptyAndPropagatesErrors() async throws {
        let server = StubServer(always: .json(#"{"start":100,"end":200,"received":0,"sent":0,"watched":0,"top_sender":null,"top_platform":null,"most_reacted":null}"#))
        let result = try await server.client().wrapped(start: .distantPast, end: .now)
        #expect(result.watchRate == nil && result.topSender == nil && result.topPlatform == nil && result.mostReacted == nil)
        #expect(!server.requests[0].url.query()!.contains("group_id"))
        let failing = StubServer(always: .json(#"{"error":"Bad range"}"#, status: 400))
        await #expect(throws: APIError.server("Bad range")) { try await failing.client().wrapped(start: .now, end: .now) }
    }
}
