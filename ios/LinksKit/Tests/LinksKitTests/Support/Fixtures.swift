import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LinksKit

/// JSON in the shapes the Bun server sends (server/src/app.ts, accounts.ts).
enum Fixture {
    static let sam = #"{"id": "user_01SAM", "name": "Sam Lee", "avatar": "https://example.com/sam.png", "email": "sam@example.com"}"#
    static let jo = #"{"id": "legacy:Jo", "name": "Jo", "avatar": null}"#

    /// accounts.mePayload(): who I am, plus legacy people I could claim.
    static let me = #"{"user": \#(sam), "claimable": [\#(jo)]}"#

    /// The same from a server with notification settings.
    static func meWithNotifications(watched: Bool = true, reactions: Bool = true) -> String {
        #"{"user": \#(sam), "claimable": [\#(jo)], "notifications": {"watched": \#(watched), "reactions": \#(reactions)}}"#
    }

    static func link(id: Int = 7, url: String = "https://www.youtube.com/watch?v=abc", platform: String = "youtube",
                     note: String = "watch this", seen: String = "{}", reactions: String = "{}",
                     groupID: Int? = 1) -> String {
        """
        {"id": \(id), \(groupID.map { #""group_id": \#($0), "# } ?? "")"url": "\(url)", "platform": "\(platform)", "title": "A video", "author": "Some Channel",
         "note": "\(note)", "thumb": "/thumbs/\(id)", "meta": "done", "added_by": "user_01SAM",
         "added_at": 1794525713.5, "seen": \(seen), "reactions": \(reactions)}
        """
    }

    /// getGroup(): a chat Sam started with Jo in it.
    static func group(id: Int = 5, name: String = "Film club", isDefault: Bool = false,
                      members: String = #"["user_01SAM", "user_01JO"]"#) -> String {
        """
        {"id": \(id), "name": "\(name)", "created_by": "user_01SAM", "created_at": 1794525700,
         "default": \(isDefault), "members": \(members)}
        """
    }

    static func decode<T: Decodable>(_ type: T.Type = T.self, _ json: String) throws -> T {
        try APIClient.decoder.decode(T.self, from: Data(json.utf8))
    }
}

/// Runs `body` with the inbox cache and thumbnails in a fresh temp folder (instead of the App Group
/// or ~/Library/Caches), then deletes the folder.
func withTempCache<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "LinksKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await CacheLocation.$testRoot.withValue(dir) { try await body(dir) }
}

enum TestImage {
    /// A solid-color PNG, standing in for a thumbnail the server returns.
    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.09, green: 0.8, blue: 0.48, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func type(_ data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType).map { $0 as String }
    }
}
