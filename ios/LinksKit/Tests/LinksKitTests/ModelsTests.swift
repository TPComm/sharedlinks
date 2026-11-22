import Foundation
import Testing
@testable import LinksKit

@Suite("Platform")
struct PlatformTests {
    /// Same table as the server's PLATFORMS/onDomain() in server/src/links.ts.
    @Test(arguments: [
        ("tiktok.com", Platform.tiktok), ("www.tiktok.com", .tiktok), ("vm.tiktok.com", .tiktok), ("WWW.TikTok.COM", .tiktok),
        ("instagram.com", .instagram), ("www.instagram.com", .instagram), ("instagr.am", .instagram),
        ("youtube.com", .youtube), ("m.youtube.com", .youtube), ("music.youtube.com", .youtube), ("youtu.be", .youtube),
        ("x.com", .x), ("twitter.com", .x), ("mobile.twitter.com", .x),
        ("reddit.com", .reddit), ("old.reddit.com", .reddit), ("redd.it", .reddit),
        ("facebook.com", .facebook), ("m.facebook.com", .facebook), ("fb.watch", .facebook),
        // Only the domain or its subdomains, not look-alikes.
        ("eviltiktok.com", .web), ("tiktok.com.evil.example", .web), ("box.com", .web), ("notyoutu.be", .web),
        ("example.com", .web), ("", .web),
    ])
    func fromHost(_ host: String, _ platform: Platform) {
        #expect(Platform(host: host) == platform)
    }

    @Test func noHostIsTheWeb() {
        #expect(Platform(host: nil) == .web)
    }

    @Test func decodesKnownNamesAndFallsBackForNewOnes() throws {
        for platform in Platform.allCases {
            #expect(try Fixture.decode(Platform.self, "\"\(platform.rawValue)\"") == platform)
        }
        // A platform added to the server later must not break older apps.
        #expect(try Fixture.decode(Platform.self, #""mastodon""#) == .web)
        #expect(try Fixture.decode(Platform.self, #""TikTok""#) == .web)
        #expect(throws: DecodingError.self) { try Fixture.decode(Platform.self, "3") }
    }

    @Test func encodesAsTheServerName() throws {
        let data = try APIClient.encoder.encode([Platform.youtube, .x])
        #expect(String(decoding: data, as: UTF8.self) == #"["youtube","x"]"#)
    }

    @Test func everyPlatformHasWords() {
        for platform in Platform.allCases {
            #expect(!platform.label.isEmpty && !platform.noun.isEmpty && !platform.glyph.isEmpty)
        }
        #expect(Set(Platform.allCases.map(\.label)).count == Platform.allCases.count)
    }

    @Test func trademarkNoticeNamesEveryPlatformAndItsOwner() {
        let notice = Platform.trademarkNotice()
        #expect(notice.hasPrefix("TikTok is a trademark of ByteDance Ltd. Instagram is a trademark of Instagram, LLC."))
        for platform in Platform.allCases where platform != .web {
            #expect(notice.contains("\(platform.label) is a trademark of \(platform.trademarkOwner!)"))
        }
        #expect(Platform.web.trademarkOwner == nil)
        #expect(!notice.contains(".."))
        #expect(notice.hasSuffix("Links isn't affiliated with or endorsed by any of them."))
    }

    @Test func shortTrademarkNoticeNamesTikTokAndInstagram() {
        #expect(Platform.shortTrademarkNotice == "TikTok is a trademark of ByteDance Ltd. "
            + "Instagram is a trademark of Instagram, LLC. Links isn't affiliated with or endorsed by either.")
    }

    @Test(arguments: [
        (Platform.tiktok, "Open in TikTok"), (.instagram, "Open in Instagram"), (.youtube, "Open in YouTube"),
        (.x, "Open in X"), (.reddit, "Open in Reddit"), (.facebook, "Open in Facebook"), (.web, "Open in Browser"),
    ])
    func openTitle(_ platform: Platform, _ title: String) {
        #expect(platform.openTitle == title)
    }
}

@Suite("LinkUser")
struct LinkUserTests {
    @Test func decodesTheServerShape() throws {
        let user = try Fixture.decode(LinkUser.self, Fixture.sam)
        #expect(user == LinkUser(id: "user_01SAM", name: "Sam Lee", avatar: URL(string: "https://example.com/sam.png"),
                                 email: "sam@example.com"))
    }

    /// An odd avatar only costs the picture, never the person.
    @Test(arguments: [#""avatar": null,"#, #""avatar": "","#, #""avatar": "https://exa}mple.com/a.png","#, #""avatar": 42,"#, ""])
    func badAvatarsAreDropped(_ avatar: String) throws {
        let user = try Fixture.decode(LinkUser.self, #"{"id": "u1", \#(avatar) "name": "Sam", "unknown": [1, 2]}"#)
        #expect(user.avatar == nil)
        #expect(user.email == nil)
        #expect(user.name == "Sam")
    }

    @Test func idAndNameAreRequired() {
        #expect(throws: DecodingError.self) { try Fixture.decode(LinkUser.self, #"{"id": "u1"}"#) }
        #expect(throws: DecodingError.self) { try Fixture.decode(LinkUser.self, #"{"name": "Sam"}"#) }
        #expect(throws: DecodingError.self) { try Fixture.decode(LinkUser.self, #"{"id": "u1", "name": null}"#) }
    }

    @Test func roundTrips() throws {
        for user in [LinkUser(id: "u1", name: "Sam", avatar: URL(string: "https://example.com/a.png"), email: "s@example.com"),
                     LinkUser(id: "legacy:Jo", name: "Jo")] {
            #expect(try Fixture.decode(LinkUser.self, String(decoding: APIClient.encoder.encode(user), as: UTF8.self)) == user)
        }
    }

    @Test(arguments: [("Sam Lee", "SL"), ("sam", "S"), ("Mary Jane Watson", "MJ"), ("  sam   lee ", "SL"),
                      ("élodie durand", "ÉD"), ("", "")])
    func initials(_ name: String, _ initials: String) {
        #expect(LinkUser(id: "u", name: name).initials == initials)
    }

    @Test func legacyPeople() {
        #expect(LinkUser(id: "legacy:Jo", name: "Jo").isLegacy)
        #expect(!LinkUser(id: "user_01JO", name: "legacy:Jo").isLegacy)
    }
}

@Suite("SharedLink")
struct SharedLinkTests {
    static let required = #""id": 1, "url": "https://example.com/a", "platform": "web", "added_by": "u1", "added_at": 1700000000"#

    @Test func optionalFieldsDefault() throws {
        let link = try Fixture.decode(SharedLink.self, "{\(Self.required)}")
        #expect(link.title == nil && link.author == nil && link.thumb == nil)
        #expect(link.note == "")
        #expect(link.meta == "done")
        #expect(link.seen.isEmpty && link.reactions.isEmpty)
        #expect(link.addedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func nullsAreTheSameAsMissing() throws {
        let json = #"{\#(Self.required), "title": null, "author": null, "note": null, "thumb": null, "meta": null, "seen": null, "reactions": null, "new_field": {"x": 1}}"#
        let link = try Fixture.decode(SharedLink.self, json)
        #expect(try Fixture.decode(SharedLink.self, "{\(Self.required)}") == link)
    }

    @Test(arguments: ["id", "url", "added_by", "added_at", "platform"])
    func requiredFields(_ key: String) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data("{\(Self.required)}".utf8)) as? [String: Any])
        object[key] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try APIClient.decoder.decode(SharedLink.self, from: data) }
    }

    @Test(arguments: ["", "https://news.example.com}/", "https://exa mple.com/"])
    func unusableURLsAreRejected(_ url: String) {
        let json = #"{"id": 1, "url": "\#(url)", "platform": "web", "added_by": "u1", "added_at": 1}"#
        #expect(throws: DecodingError.self) { try Fixture.decode(SharedLink.self, json) }
    }

    @Test func urlsAreParsedStrictlyFirst() throws {
        // Valid escapes are kept byte for byte (the server's spelling is the duplicate key).
        #expect(URL.webURL("https://example.com/caf%C3%A9%7Cmenu")?.absoluteString == "https://example.com/caf%C3%A9%7Cmenu")
        #expect(URL.webURL("https://www.youtube.com/watch?v=abc&t=10")?.absoluteString == "https://www.youtube.com/watch?v=abc&t=10")
        // Only what the strict parser refuses goes through the lenient one.
        #expect(URL.webURL("https://example.com/a b")?.absoluteString == "https://example.com/a%20b")
        #expect(URL.webURL("") == nil)
    }

    @Test func roundTripsWithServerFieldNames() throws {
        let link = SharedLink(id: 4, url: URL(string: "https://www.tiktok.com/@/video/7301234567890123456")!, platform: .tiktok,
                              title: "Dance", author: "@a", note: "ha", thumb: "/thumbs/4", meta: "pending", addedBy: "user_01SAM",
                              addedAt: Date(timeIntervalSince1970: 1794525713.25),
                              seen: ["user_01ME": Date(timeIntervalSince1970: 1794525800)], reactions: ["user_01ME": "🔥"])
        let data = try APIClient.encoder.encode(link)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The widget's cache is read back with the same decoder, so keys and dates match the API.
        #expect(object["added_by"] as? String == "user_01SAM")
        #expect(object["added_at"] as? Double == 1794525713.25)
        #expect(object["platform"] as? String == "tiktok")
        #expect(object["addedBy"] == nil)
        #expect(try APIClient.decoder.decode(SharedLink.self, from: data) == link)
    }

    @Test func decodesTheShareTokenAndPage() throws {
        let json = #"{\#(Self.required), "token": "AbC-_09", "share_url": "https://links.example.com/l/AbC-_09"}"#
        let link = try Fixture.decode(SharedLink.self, json)
        #expect(link.token == "AbC-_09")
        #expect(link.shareURL?.absoluteString == "https://links.example.com/l/AbC-_09")
        #expect(link.shareableURL.absoluteString == "https://links.example.com/l/AbC-_09")
        let object = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(link)) as? [String: Any])
        #expect(object["share_url"] as? String == "https://links.example.com/l/AbC-_09")
        #expect(object["token"] as? String == "AbC-_09")
        #expect(try APIClient.decoder.decode(SharedLink.self, from: APIClient.encoder.encode(link)) == link)
    }

    @Test(arguments: ["", #""token": null, "share_url": null,"#, #""share_url": "","#, #""share_url": 42,"#,
                      #""share_url": "sharedlinks://l/abc","#, #""share_url": "https:/l/abc","#])
    func olderServersShareTheOriginalLink(_ fields: String) throws {
        let link = try Fixture.decode(SharedLink.self, "{\(fields) \(Self.required)}")
        #expect(link.shareURL == nil)
        #expect(link.shareableURL == link.url)
        #expect(link.shareableURL.absoluteString == "https://example.com/a")
    }

    @Test func pendingMeansThePreviewIsLoading() {
        func link(_ meta: String) -> SharedLink { SharedLink(id: 1, url: URL(string: "https://x.com")!, platform: .x, meta: meta, addedBy: "u") }
        #expect(link("pending").isLoadingPreview)
        #expect(!link("done").isLoadingPreview)
        #expect(!link("failed").isLoadingPreview)
    }
}

@Suite("Display titles")
struct DisplayTitleTests {
    @Test(arguments: [
        (Platform.tiktok, "https://www.tiktok.com/@/video/7301234567890123456", "TikTok"),
        (.instagram, "https://www.instagram.com/reel/Cxyz", "Instagram reel"),
        (.instagram, "https://www.instagram.com/p/Cxyz", "Instagram post"),
        (.youtube, "https://www.youtube.com/watch?v=abc", "YouTube link"),
        (.x, "https://x.com/someone/status/1", "Post on X"),
        (.reddit, "https://www.reddit.com/r/swift/comments/1", "Reddit post"),
        (.facebook, "https://www.facebook.com/watch?v=1", "Facebook post"),
        (.web, "https://www.example.com/article", "example.com"),
        (.web, "https://news.example.com/a", "news.example.com"),
        (.web, "https://wwwexample.com/a", "wwwexample.com"),
        (.web, "file:///tmp/a", "Link"),
    ])
    func fallsBackByPlatform(_ platform: Platform, _ url: String, _ title: String) {
        let link = SharedLink(id: 1, url: URL(string: url)!, platform: platform, addedBy: "u")
        #expect(link.displayTitle == title)
        var empty = link
        empty.title = ""
        #expect(empty.displayTitle == title)
    }

    @Test func realTitleWins() {
        let link = SharedLink(id: 1, url: URL(string: "https://www.instagram.com/reel/C1")!, platform: .instagram,
                              title: "Sunset", addedBy: "u")
        #expect(link.displayTitle == "Sunset")
    }
}

@Suite("Rich previews")
struct RichPreviewTests {
    @Test func decodesTheRichPreviewFields() throws {
        let link = try Fixture.decode(SharedLink.self, """
        {"id": 1, "url": "https://www.instagram.com/reel/C1/", "platform": "instagram", "title": "beach day",
         "author": "@sam", "description": "12K likes, 40 comments", "site_name": "Instagram",
         "thumb": "/thumbs/1", "thumb_w": 640, "thumb_h": 1136, "meta": "done", "added_by": "u", "added_at": 1}
        """)
        #expect(link.summary == "12K likes, 40 comments")
        #expect(link.siteName == "Instagram")
        #expect(link.thumbWidth == 640 && link.thumbHeight == 1136)
        #expect(link.isPortrait)
        #expect(abs(link.thumbAspect - 640.0 / 1136.0) < 0.0001)
    }

    @Test func olderServersAndOddSizesStillDecode() throws {
        let link = try Fixture.decode(SharedLink.self, """
        {"id": 1, "url": "https://example.com/a", "platform": "web", "thumb_w": "wide", "added_by": "u", "added_at": 1}
        """)
        #expect(link.summary == nil && link.siteName == nil && link.thumbWidth == nil)
        #expect(link.thumbAspect == 1.91)
    }

    @Test(arguments: [
        (Platform.tiktok, 9.0 / 16.0), (.instagram, 9.0 / 16.0), (.youtube, 16.0 / 9.0), (.web, 1.91), (.x, 1.91),
    ])
    func unknownSizeGuessesByPlatform(_ platform: Platform, _ aspect: Double) {
        let link = SharedLink(id: 1, url: URL(string: "https://example.com")!, platform: platform, addedBy: "u")
        #expect(link.thumbAspect == aspect)
    }

    @Test func aspectIsClamped() {
        func aspect(_ w: Int, _ h: Int) -> Double {
            SharedLink(id: 1, url: URL(string: "https://example.com")!, platform: .web, thumbWidth: w, thumbHeight: h,
                       addedBy: "u").thumbAspect
        }
        #expect(aspect(100, 1000) == 9.0 / 16.0)
        #expect(aspect(1000, 100) == 2)
        #expect(aspect(1200, 630) == 1200.0 / 630.0)
        #expect(aspect(0, 100) == 1.91)
    }

    @Test func sourceName() {
        let url = URL(string: "https://www.theguardian.com/a")!
        #expect(SharedLink(id: 1, url: url, platform: .web, siteName: "The Guardian", addedBy: "u").sourceName == "The Guardian")
        #expect(SharedLink(id: 1, url: url, platform: .web, addedBy: "u").sourceName == "theguardian.com")
        #expect(SharedLink(id: 1, url: URL(string: "https://youtu.be/x")!, platform: .youtube, addedBy: "u").sourceName == "YouTube")
    }

    @Test func failedPreview() {
        let link = SharedLink(id: 1, url: URL(string: "https://example.com")!, platform: .web, meta: "failed", addedBy: "u")
        #expect(link.previewFailed && !link.isLoadingPreview)
    }
}

@Suite("Inbox decoding")
struct InboxDecodingTests {
    @Test func badRowsAreSkippedNotFatal() throws {
        let json = """
        {"me": "u1", "server_version": 3,
         "users": [{"id": "u1", "name": "Me"}, {"id": "u2"}, 7, {"id": "u3", "name": "Alex", "avatar": "nope nope"}],
         "links": [
           {"id": 1, "url": "https://example.com/1", "platform": "web", "added_by": "u2"},
           {"id": 2, "url": "", "platform": "web", "added_by": "u2", "added_at": 2},
           "garbage",
           {"id": "3", "url": "https://example.com/3", "platform": "web", "added_by": "u2", "added_at": 3},
           {"id": 4, "url": "https://example.com/4", "platform": "threads", "added_by": "u2", "added_at": 4, "seen": {"u1": "yesterday"}},
           {"id": 5, "url": "https://example.com/5", "platform": "threads", "added_by": "u2", "added_at": 5}
         ]}
        """
        let state = try Fixture.decode(InboxState.self, json)
        #expect(state.me == "u1")
        #expect(state.users.map(\.id) == ["u1", "u3"])
        #expect(state.links.map(\.id) == [5])
        #expect(try #require(state.links.first).platform == .web)
    }

    @Test(arguments: [#"{"users": [], "links": []}"#, #"{"me": "u1", "links": []}"#, #"{"me": "u1", "users": []}"#,
                      #"{"me": "u1", "users": null, "links": []}"#, "[]"])
    func theEnvelopeIsRequired(_ json: String) {
        #expect(throws: DecodingError.self) { try Fixture.decode(InboxState.self, json) }
    }

    @Test func emptyIsEmpty() {
        #expect(InboxState.empty.me.isEmpty)
        #expect(InboxState.empty.links(for: .all).isEmpty)
        #expect(InboxState.empty.meUser == nil)
        #expect(InboxState.empty.otherPeople.isEmpty)
    }

    @Test func customReactionsDecodeWithoutASpecialCase() throws {
        let link = try Fixture.decode(SharedLink.self, Fixture.link(reactions: #"{"friend":"👩🏽‍💻"}"#))
        #expect(link.reactions == ["friend": "👩🏽‍💻"])
    }
}
