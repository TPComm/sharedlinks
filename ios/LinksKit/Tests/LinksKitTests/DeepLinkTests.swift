import Foundation
import Testing
@testable import LinksKit

@Suite("Deep links")
struct DeepLinkTests {
    @Test(arguments: [DeepLink.open(linkID: 42), .open(linkID: 0), .open(linkID: Int.max), .add, .inbox])
    func roundTrip(_ link: DeepLink) {
        #expect(link.url.scheme == LinksConfig.urlScheme)
        #expect(DeepLink(url: link.url) == link)
    }

    @Test func urlsTheWidgetsUse() {
        #expect(DeepLink.open(linkID: 42).url.absoluteString == "sharedlinks://open/42")
        #expect(DeepLink.add.url.absoluteString == "sharedlinks://add")
        #expect(DeepLink.inbox.url.absoluteString == "sharedlinks://inbox")
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
