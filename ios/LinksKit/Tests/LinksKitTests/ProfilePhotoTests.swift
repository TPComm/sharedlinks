import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LinksKit

@Suite("ProfilePhoto")
struct ProfilePhotoTests {
    /// A PNG of `width` x `height`, red, with a transparent left half.
    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    static func size(of data: Data) throws -> (type: String, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (CGImageSourceGetType(source) as String? ?? "",
                properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test(arguments: [(3000, 2000), (900, 1600), (512, 512)])
    func aLargePhotoBecomesA512pxSquareJPEG(width: Int, height: Int) throws {
        let jpeg = try #require(ProfilePhoto.jpeg(from: try Self.png(width: width, height: height)))
        let out = try Self.size(of: jpeg)
        #expect(out.type == UTType.jpeg.identifier)
        #expect(out.width == out.height)
        #expect((ProfilePhoto.side - 2)...ProfilePhoto.side ~= out.width)
        #expect(jpeg.count < 200_000)
    }

    @Test func aSmallPhotoIsCroppedButNotEnlarged() throws {
        let out = try Self.size(of: try #require(ProfilePhoto.jpeg(from: try Self.png(width: 120, height: 80))))
        #expect(out.width == 80 && out.height == 80)
    }

    @Test func somethingThatIsNotAnImageIsRefused() {
        #expect(ProfilePhoto.jpeg(from: Data("not a photo".utf8)) == nil)
        #expect(ProfilePhoto.jpeg(from: Data()) == nil)
    }
}
