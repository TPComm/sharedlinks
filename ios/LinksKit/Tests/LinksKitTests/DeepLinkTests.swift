import Foundation
import Testing
@testable import LinksKit

@Suite("Deep links")
struct DeepLinkTests {
    @Test(arguments: [DeepLink.open(linkID: 42), .open(linkID: 0), .open(linkID: Int.max), .add, .inbox,
                      .invite(token: String(repeating: "a", count: 43))])
    func roundTrip(_ link: DeepLink) {
        #expect(link.url.scheme == LinksConfig.urlScheme)
        #expect(DeepLink(url: link.url) == link)
    }

    @Test func urlsTheWidgetsUse() {
        #expect(DeepLink.open(linkID: 42).url.absoluteString == "sharedlinks://open/42")
        #expect(DeepLink.add.url.absoluteString == "sharedlinks://add")
        #expect(DeepLink.inbox.url.absoluteString == "sharedlinks://inbox")
    }

    static let token = "AbC-_0123456789abcdefghijklmnopqrstuvwxyzAB"

    @Test(arguments: [
        "sharedlinks://invite/\(token)",
        "sharedlinks:///invite/\(token)",
        "https://links.example.com/invite/\(token)",
        "https://LINKS.example.com/invite/\(token)?utm=messages",
        "https://links.example.com/links/invite/\(token)",  // the server behind a path prefix
    ])
    func invites(_ url: String) throws {
        #expect(Self.token.count == 43)
        #expect(DeepLink(url: try #require(URL(string: url)), webHost: "links.example.com") == .invite(token: Self.token))
        #expect(DeepLink.invite(token: Self.token).url.absoluteString == "sharedlinks://invite/\(Self.token)")
    }

    @Test(arguments: [
        "https://elsewhere.test/invite/\(token)",            // not this server's page
        "http://links.example.com/invite/\(token)",
        "https://links.example.com/invite/short",
        "https://links.example.com/invite/\(token)/x",
        "https://links.example.com/open/42",
        "sharedlinks://invite",
        "sharedlinks://invite/short",
        "sharedlinks://invite/\(token.dropLast())!",
    ])
    func ignoresOtherInviteURLs(_ url: String) throws {
        #expect(DeepLink(url: try #require(URL(string: url)), webHost: "links.example.com") == nil)
    }

    @Test(arguments: [
        ("sharedlinks://open/42", DeepLink.open(linkID: 42)),
        ("sharedlinks:///open/42", .open(linkID: 42)),      // no host, all path
        ("sharedlinks://open/42/", .open(linkID: 42)),
        ("sharedlinks://open/42/extra", .open(linkID: 42)),
        ("sharedlinks://open/42?from=widget", .open(linkID: 42)),
        ("sharedlinks://add", .add),
        ("sharedlinks://add/anything", .add),
        ("sharedlinks://inbox", .inbox),
        // A link we can't identify still opens the app on the inbox.
        ("sharedlinks://open", .inbox),
        ("sharedlinks://open/", .inbox),
        ("sharedlinks://open/abc", .inbox),
        ("sharedlinks://open/4.2", .inbox),
        ("sharedlinks://open/99999999999999999999999", .inbox),
    ])
    func parses(_ url: String, _ link: DeepLink) throws {
        #expect(DeepLink(url: try #require(URL(string: url))) == link)
    }

    @Test(arguments: [
        "https://open/42",                  // wrong scheme
        "links://open/42",
        "sharedlinks-dev://open/42",
        "sharedlinks://auth/callback?code=abc&state=xyz",  // the sign-in callback isn't a deep link
        "sharedlinks://settings",
        "sharedlinks:",
        "sharedlinks://",
    ])
    func ignores(_ url: String) throws {
        #expect(DeepLink(url: try #require(URL(string: url))) == nil)
    }
}
