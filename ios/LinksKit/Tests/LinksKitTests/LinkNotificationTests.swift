import Foundation
import Testing
@testable import LinksKit

@Suite("New-link notifications")
struct LinkNotificationTests {
    @Test func readsWhatTheServerSends() throws {
        // As server/src/push.ts sends it, through APNs' JSON (numbers arrive as NSNumber).
        let json = #"""
        {"aps": {"alert": {"title": "Sam in Movie night", "body": "sent a link: Cats"}, "category": "NEW_LINK", "mutable-content": 1,
                 "thread-id": "links-group-5"},
         "link_id": 7, "sender_id": "user_01SAM", "group_id": 5, "sender_name": "Sam",
         "sender_avatar": "https://photos.test/sam.png", "chat": "Movie night", "thumb": "/thumbs/7/2"}
        """#
        let userInfo = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        let note = try #require(LinkNotification(userInfo: userInfo))
        #expect(note == LinkNotification(linkID: 7, groupID: 5, senderID: "user_01SAM", senderName: "Sam",
                                         senderAvatar: URL(string: "https://photos.test/sam.png"),
                                         chat: "Movie night", thumb: "/thumbs/7/2", threadID: "links-group-5"))
        #expect(note.conversationID == "links-group-5")
    }

    @Test func aPushFromBeforeRichNotificationsStillOpensItsLink() throws {
        let note = try #require(LinkNotification(userInfo: ["link_id": 7, "sender_id": "user_01SAM", "group_id": 1]))
        #expect(note.senderName == nil)
        #expect(note.thumb == nil)
        #expect(note.conversationID == LinkGroup.defaultConversationID)
    }

    @Test func anUnnamedChatKeepsItsOwnConversation() throws {
        // The server only sends `chat` for a named chat; the thread id still says which one.
        let note = try #require(LinkNotification(userInfo: [
            "aps": ["thread-id": "links-group-9"], "link_id": 7, "group_id": 9, "sender_name": "Sam",
        ]))
        #expect(note.chat == nil)
        #expect(note.conversationID == "links-group-9")
    }

    @Test func otherPushesAreNotNewLinks() {
        #expect(LinkNotification(userInfo: ["aps": ["badge": 2]]) == nil)
        #expect(LinkNotification(userInfo: ["link_id": "seven"]) == nil)
    }

    @Test func onlyFetchesThumbnailsFromOurServerAndPhotosOverHTTP() throws {
        let note = try #require(LinkNotification(userInfo: [
            "link_id": "7", "sender_avatar": "file:///etc/passwd", "thumb": "https://elsewhere.test/thumbs/7",
            "sender_name": "  ", "chat": "",
        ]))
        #expect(note.linkID == 7)
        #expect(note.senderAvatar == nil)
        #expect(note.thumb == nil)
        #expect(note.senderName == nil)
        #expect(note.chat == nil)
        #expect(LinkNotification(userInfo: ["link_id": 7, "thumb": "/thumbs/../api/me"])?.thumb == nil)
    }

    @Test(arguments: [
        ("image/jpeg", "jpg"), ("image/png; charset=binary", "png"), ("IMAGE/WEBP", "webp"),
        ("text/html", nil), (nil, nil),
    ] as [(String?, String?)])
    func attachmentFileExtension(_ type: String?, _ ext: String?) {
        #expect(LinkNotification.fileExtension(forContentType: type) == ext)
    }

    @Test func fetchesAThumbnailByPathWithTheSession() async throws {
        let png = TestImage.png(width: 4, height: 4)
        let server = StubServer(always: .http(status: 200, body: png, contentType: "image/png"))
        let (data, type) = try await server.client().thumbnail(path: "/thumbs/7/2")
        #expect(data == png)
        #expect(type == "image/png")
        let request = try #require(server.requests.first)
        #expect(request.url.path == "/thumbs/7/2")
        #expect(request.header("Authorization") == "Bearer tok_123")
    }

    @Test func registersTheActionsTheAppHandles() {
        #expect(LinkNotification.category == "NEW_LINK")
        #expect(Set([LinkNotification.markSeenAction, LinkNotification.commentAction]).count == 2)
    }
}
