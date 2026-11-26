import Foundation
import Testing
@testable import LinksKit

@Suite("Deep links")
struct DeepLinkTests {
    @Test func catchUpDestinationRoundTrips() throws {
        let destination = try #require(LinkNotification.destination(userInfo: ["open": "queue"]))
        #expect(DeepLink(url: destination.url) == .inbox)
    }
    @Test(arguments: [DeepLink.open(linkID: 42), .open(linkID: 0), .open(linkID: Int.max), .add, .inbox,
                      .link(token: "AbC-_09"), .invite(token: "tok"), .group(id: "42")])
    func roundTrip(_ link: DeepLink) {
        #expect(link.url.scheme == LinksConfig.urlScheme)
        #expect(DeepLink(url: link.url) == link)
    }

    @Test func urlsTheWidgetsUse() {
        #expect(DeepLink.open(linkID: 42).url.absoluteString == "sharedlinks://open/42")
        #expect(DeepLink.add.url.absoluteString == "sharedlinks://add")
        #expect(DeepLink.inbox.url.absoluteString == "sharedlinks://inbox")
        #expect(DeepLink.link(token: "t").url.absoluteString == "sharedlinks://l/t")
        #expect(DeepLink.invite(token: "t").url.absoluteString == "sharedlinks://invite/t")
        #expect(DeepLink.group(id: "g").url.absoluteString == "sharedlinks://g/g")
    }

    @Test(arguments: [
        ("https://links.example.com/l/abc", DeepLink.link(token: "abc")),
        ("https://links.example.com/l/abc/", .link(token: "abc")),
        ("https://links.example.com/l/abc?utm=x#top", .link(token: "abc")),
        ("https://LINKS.Example.com/invite/Tok_1-x", .invite(token: "Tok_1-x")),
        ("https://links.example.com/g/42", .group(id: "42")),
        ("https://links.example.com/l/\(String(repeating: "a", count: 64))", .link(token: String(repeating: "a", count: 64))),
    ])
    func parsesUniversalLinks(_ url: String, _ link: DeepLink) throws {
        #expect(DeepLink(url: try #require(URL(string: url)), associatedDomain: "links.example.com") == link)
    }

    @Test(arguments: [
        "http://links.example.com/l/abc",            // https only
        "https://other.example.com/l/abc",
        "https://links.example.com.evil.test/l/abc",
        "https://links.example.com:8443/l/abc",
        "https://links.example.com/",
        "https://links.example.com/l",
        "https://links.example.com/l/",
        "https://links.example.com/l/a/b",
        "https://links.example.com/l/a.b",
        "https://links.example.com/l/%C3%A9",
        "https://links.example.com/l/\(String(repeating: "a", count: 65))",
        "https://links.example.com/open/42",         // the widget links are sharedlinks:// only
        "https://links.example.com/add",
        "https://links.example.com/api/state",
        "https://links.example.com/auth/callback?code=abc",
        "https://links.example.com/thumbs/1",
    ])
    func ignoresOtherServerURLs(_ url: String) throws {
        #expect(DeepLink(url: try #require(URL(string: url)), associatedDomain: "links.example.com") == nil)
    }

    @Test func noAssociatedDomainNoUniversalLinks() throws {
        let url = try #require(URL(string: "https://links.example.com/l/abc"))
        #expect(DeepLink(url: url, associatedDomain: nil) == nil)
        #expect(DeepLink(url: url, associatedDomain: "") == nil)
        #expect(LinksConfig.associatedDomain == nil)   // the test bundle's Info.plist has none
    }

    @Test func invitesFromTheInvitePage() throws {
        let token = "AbC-_0123456789abcdefghijklmnopqrstuvwxyzAB"
        #expect(DeepLink(url: try #require(URL(string: "sharedlinks://invite/\(token)"))) == .invite(token: token))
        #expect(DeepLink(url: try #require(URL(string: "sharedlinks:///invite/\(token)"))) == .invite(token: token))
        #expect(DeepLink(url: try #require(URL(string: "sharedlinks://invite"))) == nil)
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
        ("sharedlinks://l/abc", .link(token: "abc")),
        ("sharedlinks://invite/abc", .invite(token: "abc")),
        ("sharedlinks://g/abc", .group(id: "abc")),
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
        "sharedlinks://l",
        "sharedlinks://invite/a.b",
        "sharedlinks://g/a/b",
    ])
    func ignores(_ url: String) throws {
        #expect(DeepLink(url: try #require(URL(string: url))) == nil)
    }
}
