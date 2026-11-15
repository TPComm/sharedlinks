import CoreGraphics
import Foundation
import Testing
@testable import LinksKit

@Suite("Finding links in shared text")
struct LinkTextTests {
    @Test(arguments: [
        ("lol look https://vm.tiktok.com/ZMabc/ 😂", "https://vm.tiktok.com/ZMabc/"),
        ("first https://a.example.com/1 then https://b.example.com/2", "https://a.example.com/1"),
        ("(https://example.com/x).", "https://example.com/x"),
        ("ftp://files.example.com/x then https://b.example.com/y", "https://b.example.com/y"),
        ("call tel:5551234 or https://x.com/a", "https://x.com/a"),
        ("see youtu.be/abc", "http://youtu.be/abc"),
        ("HTTPS://EXAMPLE.COM/Path", "HTTPS://EXAMPLE.COM/Path"),
    ])
    func findsTheFirstWebLink(_ text: String, _ url: String) {
        #expect(LinkText.firstURL(in: text)?.absoluteString == url)
    }

    @Test(arguments: ["", "no link here", "mail me@example.com", "ftp://files.example.com/x", "tel:5551234"])
    func findsNothing(_ text: String) {
        #expect(LinkText.firstURL(in: text) == nil)
    }

    @Test func takesASharedURL() {
        let url = URL(string: "https://www.tiktok.com/@a/video/1")!
        #expect(LinkText.webURL(fromSharedItem: url) == url)
        #expect(LinkText.webURL(fromSharedItem: url as NSURL) == url)
        #expect(LinkText.webURL(fromSharedItem: url.absoluteString) == url)
        #expect(LinkText.webURL(fromSharedItem: Data(url.absoluteString.utf8)) == url)
    }

    /// What SwiftUI's ShareLink hands the Share Extension on iOS: the public.url data, a binary
    /// property list of [string, base, {}], rather than a URL.
    @Test func readsTheURLPropertyList() throws {
        let url = URL(string: "https://example.com/links-share-sheet-practice")!
        let data = try PropertyListSerialization.data(fromPropertyList: [url.absoluteString, "", [String: String]()],
                                                      format: .binary, options: 0)
        #expect(LinkText.webURL(fromSharedItem: data) == url)
    }

    @Test func ignoresWhatIsntAWebLink() {
        #expect(LinkText.webURL(fromSharedItem: nil) == nil)
        #expect(LinkText.webURL(fromSharedItem: URL(string: "file:///tmp/x")!) == nil)
        #expect(LinkText.webURL(fromSharedItem: "tel:5551234") == nil)
        #expect(LinkText.webURL(fromSharedItem: 42) == nil)
        #expect(LinkText.webURL(fromSharedItem: "") == nil)
        #expect(LinkText.webURL(fromSharedItem: Data([0xFF, 0xFE])) == nil)
    }

    @Test(arguments: ["Episode title", "Episode: title"])
    func readsPodcastsSharedText(_ title: String) {
        let url = URL(string: "https://podcasts.apple.com/us/podcast/explain-it-to-me/id1042433083?i=1000802075437")!
        let text = "\(title)\n\(url.absoluteString)"
        #expect(LinkText.webURL(fromSharedItem: text) == url)
        #expect(LinkText.webURL(fromSharedItem: Data(text.utf8)) == url)
    }
}

@Suite("Formatting")
struct LinkFormatTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [
        (0.0, "now"), (59, "now"), (-3600, "now"),  // clock skew: a link "from the future" is new
        (60, "1m"), (119, "1m"), (3599, "59m"),
        (3600, "1h"), (86399, "23h"),
        (86400, "Yesterday"), (172_799, "Yesterday"),
    ])
    func recentTimes(_ secondsAgo: TimeInterval, _ text: String) {
        #expect(LinkFormat.ago(now.addingTimeInterval(-secondsAgo), now: now) == text)
    }

    @Test func thisWeekShowsTheWeekday() {
        for days in 2...6 {
            let date = now.addingTimeInterval(-Double(days) * 86400)
            #expect(LinkFormat.ago(date, now: now) == date.formatted(.dateTime.weekday(.abbreviated)))
        }
    }

    @Test func olderShowsTheDate() {
        let date = now.addingTimeInterval(-30 * 86400)
        #expect(LinkFormat.ago(date, now: now) == date.formatted(.dateTime.month(.abbreviated).day()))
    }

    @Test func names() {
        #expect(LinkFormat.names([]) == "")
        #expect(LinkFormat.names(["Sam"]) == "Sam")
        let three = LinkFormat.names(["Sam", "Alex", "Jo"])
        #expect(["Sam", "Alex", "Jo"].allSatisfy(three.contains))
        #expect(three == ["Sam", "Alex", "Jo"].formatted(.list(type: .and)))
    }
}

@Suite("Avatar colors")
struct AvatarPaletteTests {
    /// The web app's hash: for (ch of name) h = (h * 31 + ch.codePointAt(0)) >>> 0
    static func webHash(_ name: String) -> Int {
        var h: UInt64 = 0
        for scalar in name.unicodeScalars { h = (h * 31 + UInt64(scalar.value)) & 0xFFFF_FFFF }
        return Int(h % 8)
    }

    @Test(arguments: ["Sam", "Alex Kim", "", "Ünïcødé", "😀 party", String(repeating: "Bartholomew ", count: 20)])
    func matchesTheWebHash(_ name: String) {
        #expect(AvatarPalette.index(for: name) == Self.webHash(name))
        #expect(AvatarPalette.hex.indices.contains(AvatarPalette.index(for: name)))
    }

    @Test func knownValues() {
        #expect(AvatarPalette.index(for: "Sam") == 7)  // 83*31*31 + 97*31 + 109 = 82879; % 8 = 7
        #expect(AvatarPalette.index(for: "") == 0)
        #expect(AvatarPalette.hex.count == 8)
    }
}

@Suite("Brand mark")
struct BrandMarkTests {
    @Test func pathsScaleIntoTheRect() {
        let unit = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let rect = CGRect(x: 10, y: 20, width: 512, height: 256)
        for path in [BrandMark.graphitePath, BrandMark.greenPath] {
            let full = path(unit).boundingBoxOfPath
            let scaled = path(rect).boundingBoxOfPath
            #expect(unit.contains(full))
            #expect(abs(scaled.minX - (10 + full.minX / 2)) < 0.001)
            #expect(abs(scaled.minY - (20 + full.minY / 4)) < 0.001)
            #expect(abs(scaled.width - full.width / 2) < 0.001)
            #expect(abs(scaled.height - full.height / 4) < 0.001)
        }
    }

    @Test func colorsMatchTheIcon() {
        #expect(BrandMark.backgroundRGB == 0xEDF0F0)
        #expect(BrandMark.graphiteRGB == 0x4B5158)
        #expect(BrandMark.greenRGB == 0x16CC7B)
    }
}
