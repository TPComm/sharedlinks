import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the app uploads as a profile photo (#97): a centered square JPEG. Avatars are at most 88pt,
/// so 512px covers them at 3x and keeps the upload far under the server's 2 MB limit.
public enum ProfilePhoto {
    public static let side = 512

    /// `data` (any image ImageIO reads, upright per its EXIF orientation) cropped to a square, at
    /// most `side` pixels across, on white where it was transparent; nil if it isn't an image.
    public static func jpeg(from data: Data, side: Int = side) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Scaled so the shorter side, which the crop keeps whole, is `side`.
        let longer = max(width, height), shorter = min(width, height)
        let maxSize = shorter > side ? Int((Double(side) * Double(longer) / Double(shorter)).rounded(.up)) : longer
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let crop = min(scaled.width, scaled.height, side)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: crop, height: crop, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: crop, height: crop))
        context.draw(scaled, in: CGRect(x: (crop - scaled.width) / 2, y: (crop - scaled.height) / 2,
                                        width: scaled.width, height: scaled.height))
        guard let square = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
