import Foundation
import Testing
@testable import LinksKit

@Suite("Inbox cache")
struct InboxSnapshotTests {
    @Test func nothingCachedYet() async {
        await withTempCache { _ in
            #expect(InboxSnapshot.load() == nil)
        }
    }

    @Test func saveThenLoad() async throws {
        try await withTempCache { dir in
            InboxSnapshot.save(household)
            #expect(InboxSnapshot.load() == household)
            // The widget and Share Extension read this exact file, with the API's field names.
            let data = try Data(contentsOf: dir.appending(path: "inbox.json"))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let links = try #require(object["links"] as? [[String: Any]])
            #expect(links.first?["added_by"] as? String == "user_SAM")
        }
    }

    @Test(arguments: ["", "not json", #"{"me": "u1"}"#, #"{"me": "u1", "users": [], "links": {}}"#, "\u{0}\u{1}\u{2}"])
    func corruptCacheLoadsAsNothing(_ contents: String) async throws {
        try await withTempCache { dir in
            try Data(contents.utf8).write(to: dir.appending(path: "inbox.json"))
            #expect(InboxSnapshot.load() == nil)
            // ...and the next save replaces it.
            InboxSnapshot.save(household)
            #expect(InboxSnapshot.load() == household)
        }
    }

    @Test func aCachedRowTheAppNoLongerUnderstandsIsDropped() async throws {
        try await withTempCache { dir in
            let json = #"{"me": "u1", "users": [], "links": [\#(Fixture.link(id: 1)), {"id": 2}]}"#
            try Data(json.utf8).write(to: dir.appending(path: "inbox.json"))
            #expect(InboxSnapshot.load()?.links.map(\.id) == [1])
        }
    }

    @Test func updateChangesAndPersists() async {
        await withTempCache { _ in
            InboxSnapshot.save(household)
            InboxSnapshot.update { state in
                // What the widget does when you mark something watched from the Home Screen.
                if let i = state.links.firstIndex(where: { $0.id == 5 }) {
                    state.links[i].seen[state.me] = Date(timeIntervalSince1970: 1_800_000_999)
                }
            }
            let reloaded = InboxSnapshot.load()
            #expect(reloaded?.links(for: .toWatch).map(\.id) == [2])
            #expect(reloaded?.links.first?.seen["user_ME"] == Date(timeIntervalSince1970: 1_800_000_999))
        }
    }

    @Test func updateWithoutACacheDoesNothing() async {
        await withTempCache { dir in
            var called = false
            InboxSnapshot.update { _ in called = true }
            #expect(!called)
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "inbox.json").path()))
        }
    }

    @Test func clearRemovesInboxAndThumbnails() async throws {
        try await withTempCache { dir in
            InboxSnapshot.save(household)
            try Data([1, 2, 3]).write(to: ThumbnailStore.fileURL(5))
            InboxSnapshot.clear()
            #expect(InboxSnapshot.load() == nil)
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "thumbs").path()))
            #expect(ThumbnailStore.cached(ThumbnailStoreTests.link(5)) == nil)
        }
    }
}

@Suite("Thumbnail cache")
struct ThumbnailStoreTests {
    static func link(_ id: Int, hasThumbnail: Bool = true, version: Int? = nil) -> SharedLink {
        SharedLink(id: id, url: URL(string: "https://www.youtube.com/watch?v=\(id)")!, platform: .youtube,
                   thumb: hasThumbnail ? "/thumbs/\(id)" + (version.map { "/\($0)" } ?? "") : nil, addedBy: "u")
    }

    @Test func aReplacedThumbnailIsFetchedAgain() async throws {
        try await withTempCache { dir in
            let server = StubServer(always: .http(status: 200, body: TestImage.png(width: 64, height: 64), contentType: "image/png"))
            let store = ThumbnailStore()
            _ = await store.data(for: Self.link(5, version: 1), client: server.client())
            _ = await store.data(for: Self.link(5, version: 1), client: server.client())
            _ = await store.data(for: Self.link(5, version: 2), client: server.client())
            #expect(server.requests.map { $0.url.path() } == ["/thumbs/5/1", "/thumbs/5/2"])
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: "thumbs/5-2.jpg").path()))
            ThumbnailStore.prune(keeping: [Self.link(5, version: 2)])
            let left = try FileManager.default.contentsOfDirectory(atPath: ThumbnailStore.directory.path())
            #expect(left == ["5-2.jpg"])
        }
    }

    @Test func downloadsDownsamplesAndCaches() async throws {
        try await withTempCache { dir in
            let server = StubServer(always: .http(status: 200, body: TestImage.png(width: 1200, height: 600), contentType: "image/png"))
            let data = try #require(await ThumbnailStore().data(for: Self.link(5), client: server.client()))

            #expect(server.requests.map { $0.url.path() } == ["/thumbs/5"])
            #expect(server.requests.first?.header("Authorization") == "Bearer tok_123")
            #expect(TestImage.type(data) == "public.jpeg")
            let size = try #require(TestImage.pixelSize(data))
            #expect(size.width == ThumbnailStore.maxPixelSize && size.height == ThumbnailStore.maxPixelSize / 2)
            // Saved where the widget looks, so it can draw without a network call.
            #expect(ThumbnailStore.cached(Self.link(5)) == data)
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: "thumbs/5.jpg").path()))
        }
    }

    @Test func cachedThumbnailsSkipTheNetwork() async {
        await withTempCache { _ in
            let server = StubServer(always: .http(status: 200, body: TestImage.png(width: 64, height: 64), contentType: "image/png"))
            let store = ThumbnailStore()
            let first = await store.data(for: Self.link(5), client: server.client())
            let second = await store.data(for: Self.link(5), client: server.client())
            #expect(first != nil && first == second)
            #expect(server.requests.count == 1)
        }
    }

    @Test func concurrentRequestsShareOneDownload() async {
        await withTempCache { _ in
            let server = StubServer(always: .http(status: 200, body: TestImage.png(width: 64, height: 64), contentType: "image/png"))
            let store = ThumbnailStore()
            let client = server.client()
            async let a = store.data(for: Self.link(8), client: client)
            async let b = store.data(for: Self.link(8), client: client)
            async let c = store.data(for: Self.link(8), client: client)
            let results = await [a, b, c]
            #expect(results.allSatisfy { $0 != nil && $0 == results[0] })
            #expect(server.requests.count == 1)
        }
    }

    @Test func noThumbnailMeansNoRequest() async {
        await withTempCache { _ in
            let server = StubServer(always: .json("{}"))
            #expect(await ThumbnailStore().data(for: Self.link(5, hasThumbnail: false), client: server.client()) == nil)
            #expect(server.requests.isEmpty)
        }
    }

    @Test(arguments: [Reply.json(#"{"error": "Not found"}"#, status: 404), .fail(.notConnectedToInternet),
                      .http(status: 200, body: Data("<html>".utf8), contentType: "text/html")])
    func failuresAreNotCached(_ reply: Reply) async {
        await withTempCache { _ in
            let server = StubServer(always: reply)
            let store = ThumbnailStore()
            #expect(await store.data(for: Self.link(5), client: server.client()) == nil)
            #expect(ThumbnailStore.cached(ThumbnailStoreTests.link(5)) == nil)
            // A later attempt tries again rather than remembering the failure.
            _ = await store.data(for: Self.link(5), client: server.client())
            #expect(server.requests.count == 2)
        }
    }

    @Test func pruneKeepsOnlyCurrentLinks() async throws {
        try await withTempCache { _ in
            for name in ["1.jpg", "2.jpg", "3.jpg", "junk.tmp"] {
                try Data([0]).write(to: ThumbnailStore.directory.appending(path: name))
            }
            ThumbnailStore.prune(keeping: [2, 3, 99].map { Self.link($0) })
            let left = try FileManager.default.contentsOfDirectory(atPath: ThumbnailStore.directory.path())
            #expect(Set(left) == ["2.jpg", "3.jpg"])
        }
    }

    @Test func clearDiskRemovesEverything() async throws {
        try await withTempCache { dir in
            try Data([0]).write(to: ThumbnailStore.fileURL(1))
            ThumbnailStore.clearDisk()
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "thumbs").path()))
            #expect(ThumbnailStore.cached(Self.link(1)) == nil)
        }
    }

    @Test func downsampleRejectsNonImages() {
        #expect(ThumbnailStore.downsample(Data(), maxPixelSize: 100) == nil)
        #expect(ThumbnailStore.downsample(Data("<html></html>".utf8), maxPixelSize: 100) == nil)
    }

    @Test func downsampleFitsTheLongSide() throws {
        let tall = try #require(ThumbnailStore.downsample(TestImage.png(width: 300, height: 900), maxPixelSize: 300))
        let size = try #require(TestImage.pixelSize(tall))
        #expect(size.width == 100 && size.height == 300)
    }
}
