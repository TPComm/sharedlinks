import Foundation
import Testing
@testable import LinksKit

/// Shape of server.py's /api/state response.
let stateJSON = """
{
  "me": "user_01ME",
  "users": [
    {"id": "user_01ME", "name": "Me", "avatar": null},
    {"id": "user_01SAM", "name": "Sam", "avatar": "https://example.com/sam.png"},
    {"id": "legacy:Jo", "name": "Jo", "avatar": null}
  ],
  "links": [
    {"id": 3, "url": "https://www.tiktok.com/@a/video/1", "platform": "tiktok", "title": "Dance",
     "author": "@a", "note": "", "thumb": "/thumbs/3", "meta": "done", "added_by": "user_01SAM",
     "added_at": 1794525713.4, "seen": {}, "reactions": {"user_01SAM": "🔥"}},
    {"id": 2, "url": "https://www.instagram.com/reel/abc", "platform": "instagram", "title": null,
     "author": null, "note": "lol", "thumb": null, "meta": "failed", "added_by": "user_01SAM",
     "added_at": 1794525600, "seen": {"user_01ME": 1794525700, "legacy:Jo": 1794525650}, "reactions": {}},
    {"id": 1, "url": "https://example.com/a", "platform": "mastodon", "title": null, "author": null,
     "note": "", "thumb": null, "meta": "pending", "added_by": "user_01ME", "added_at": 1794525500,
     "seen": {"user_01SAM": 1794525510}, "reactions": {}}
  ]
}
"""

@Test func decodesServerState() throws {
    let state = try APIClient.decoder.decode(InboxState.self, from: Data(stateJSON.utf8))
    #expect(state.links.count == 3)
    // User ids with underscores survive as dictionary keys (no snake-case conversion).
    #expect(state.links[1].seen["user_01ME"] != nil)
    #expect(state.links[0].reactions["user_01SAM"] == "🔥")
    #expect(state.links[2].platform == .web)  // unknown platforms fall back
    #expect(state.user("user_01SAM")?.avatar?.host() == "example.com")
}

@Test func filtersMatchTheWebApp() throws {
    let state = try APIClient.decoder.decode(InboxState.self, from: Data(stateJSON.utf8))
    #expect(state.links(for: .toWatch).map(\.id) == [3])
    #expect(state.links(for: .watched).map(\.id) == [2])
    #expect(state.links(for: .sent).map(\.id) == [1])
    #expect(state.links(for: .all, matching: "sam dance").map(\.id) == [3])
    #expect(state.seenByOthers(state.links[1]) == ["Jo"])
    #expect(state.seenByOthers(state.links[2]) == ["Sam"])
    #expect(state.otherPeople.map(\.name) == ["Sam"])  // legacy people don't count
}

@Test func snapshotRoundTrips() throws {
    let state = try APIClient.decoder.decode(InboxState.self, from: Data(stateJSON.utf8))
    let again = try APIClient.decoder.decode(InboxState.self, from: APIClient.encoder.encode(state))
    #expect(again == state)
}

@Test func fallbackTitles() throws {
    let state = try APIClient.decoder.decode(InboxState.self, from: Data(stateJSON.utf8))
    #expect(state.links[1].displayTitle == "Instagram reel")
    #expect(state.links[2].displayTitle == "example.com")
}

@Test func findsLinksInSharedText() {
    #expect(LinkText.firstURL(in: "lol look https://vm.tiktok.com/ZMabc/ 😂")?.host() == "vm.tiktok.com")
    #expect(LinkText.firstURL(in: "www.instagram.com/reel/xyz")?.host() == "www.instagram.com")
    #expect(LinkText.firstURL(in: "no link here") == nil)
    #expect(LinkText.firstURL(in: "mail me@example.com") == nil)
}

@Test func pkceChallengeIsS256OfVerifier() {
    let pkce = PKCE()
    #expect(pkce.verifier.count == 43)
    #expect(pkce.challenge.count == 43)
    #expect(!pkce.challenge.contains("="))
    #expect(pkce.challenge != pkce.verifier)
    #expect(PKCE().state != pkce.state)
}

@Test func authorizeURLGoesThroughServer() {
    let client = APIClient(baseURL: URL(string: "https://links.example.com")!, token: nil)
    let pkce = PKCE()
    let url = client.authorizeURL(pkce: pkce, signUp: true)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(url.path() == "/auth/authorize")
    #expect(items.first { $0.name == "code_challenge" }?.value == pkce.challenge)
    #expect(items.first { $0.name == "screen_hint" }?.value == "sign-up")
}

@Test func deepLinks() {
    #expect(DeepLink(url: URL(string: "sharedlinks://open/42")!) == .open(linkID: 42))
    #expect(DeepLink(url: URL(string: "sharedlinks://add")!) == .add)
    #expect(DeepLink(url: DeepLink.open(linkID: 7).url) == .open(linkID: 7))
    #expect(DeepLink(url: URL(string: "https://open/42")!) == nil)
}

@Test func compactTimes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(LinkFormat.ago(now.addingTimeInterval(-30), now: now) == "now")
    #expect(LinkFormat.ago(now.addingTimeInterval(-300), now: now) == "5m")
    #expect(LinkFormat.ago(now.addingTimeInterval(-7200), now: now) == "2h")
    #expect(LinkFormat.ago(now.addingTimeInterval(-100_000), now: now) == "Yesterday")
}

@Test func avatarColorsMatchWebHash() {
    // JS: for (ch of "Sam") h = (h*31 + code) >>> 0;  h % 8
    #expect(AvatarPalette.index(for: "Sam") == Int((UInt32(83) &* 31 &+ 97) &* 31 &+ 109) % 8)
}

@Test func oneBadRowDoesNotBreakTheInbox() throws {
    let json = """
    {"me": "u1",
     "users": [{"id": "u1", "name": "Me", "avatar": ""}, {"id": "u2", "name": "Sam", "avatar": "https://exa}mple.com/a.png"}],
     "links": [
       {"id": 1, "url": "https://news.example.com}/", "platform": "web", "added_by": "u2", "added_at": 1, "seen": {}, "reactions": {}},
       {"id": 2, "url": "https://example.com/ok", "platform": "web", "added_by": "u2", "added_at": 2, "seen": {}, "reactions": {}}
     ]}
    """
    let state = try APIClient.decoder.decode(InboxState.self, from: Data(json.utf8))
    #expect(state.links.map(\.id) == [2])
    #expect(state.users.count == 2)
    #expect(state.users.allSatisfy { $0.avatar == nil })
}

@Test func storedURLsAreNotReEscaped() throws {
    let json = """
    {"id": 1, "url": "https://example.com/caf%C3%A9%7Cmenu", "platform": "web", "added_by": "u", "added_at": 1}
    """
    let link = try APIClient.decoder.decode(SharedLink.self, from: Data(json.utf8))
    #expect(link.url.absoluteString == "https://example.com/caf%C3%A9%7Cmenu")
    #expect(link.note == "" && link.seen.isEmpty)
}
