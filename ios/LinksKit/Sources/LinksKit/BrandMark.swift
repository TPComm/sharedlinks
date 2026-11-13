import CoreGraphics

/// The app icon's two overlapping bookmarks (assets/icon/SharedLinks.icon), as vector paths, so the
/// sign-in screen and the share-sheet group picture match the icon exactly.
/// Geometry comes from assets/icon/source/B/*.svg (a 1024×1024 canvas).
public enum BrandMark {
    /// Icon background (#EDF0F0), graphite bookmark (#4B5158), green bookmark (#16CC7B).
    public static let backgroundRGB: UInt32 = 0xEDF0F0
    public static let graphiteRGB: UInt32 = 0x4B5158
    public static let greenRGB: UInt32 = 0x16CC7B

    /// The back bookmark, scaled into `rect`.
    public static func graphitePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let p = point(in: rect)
        path.move(to: p(411.5, 136.53))
        path.addCurve(to: p(525.27, 136.53), control1: p(447.53, 102.4), control2: p(489.24, 104.3))
        path.addLine(to: p(665.6, 274.96))
        path.addCurve(to: p(688.36, 422.87), control1: p(713.01, 318.58), control2: p(716.8, 375.47))
        path.addCurve(to: p(392.53, 678.87), control1: p(637.16, 504.41), control2: p(536.65, 591.64))
        path.addCurve(to: p(303.41, 650.43), control1: p(350.81, 705.42), control2: p(314.79, 692.15))
        path.addLine(to: p(282.55, 551.82))
        path.addCurve(to: p(231.35, 512), control1: p(276.86, 521.48), control2: p(259.79, 506.31))
        path.addLine(to: p(151.7, 527.17))
        path.addCurve(to: p(89.13, 483.56), control1: p(108.09, 536.65), control2: p(83.44, 517.69))
        path.addCurve(to: p(132.74, 411.5), control1: p(92.92, 460.8), control2: p(108.09, 436.15))
        path.closeSubpath()
        return path
    }

    /// The front bookmark, scaled into `rect`.
    public static func greenPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let p = point(in: rect)
        path.move(to: p(527.17, 390.64))
        path.addCurve(to: p(640.95, 383.05), control1: p(563.2, 352.71), control2: p(603.02, 352.71))
        path.addLine(to: p(813.51, 532.86))
        path.addCurve(to: p(931.08, 675.08), control1: p(885.57, 593.54), control2: p(927.29, 637.16))
        path.addCurve(to: p(862.81, 737.66), control1: p(938.67, 714.9), control2: p(910.22, 739.56))
        path.addLine(to: p(786.96, 735.76))
        path.addCurve(to: p(733.87, 781.27), control1: p(756.62, 733.87), control2: p(739.56, 750.93))
        path.addLine(to: p(711.11, 872.3))
        path.addCurve(to: p(627.67, 898.84), control1: p(701.63, 917.81), control2: p(663.7, 927.29))
        path.addCurve(to: p(534.76, 809.72), control1: p(595.44, 876.09), control2: p(566.99, 845.75))
        path.addLine(to: p(405.81, 676.98))
        path.addCurve(to: p(394.43, 542.34), control1: p(360.3, 631.47), control2: p(360.3, 580.27))
        path.addLine(to: p(512, 405.81))
        path.addCurve(to: p(527.17, 390.64), control1: p(515.79, 400.12), control2: p(521.48, 394.43))
        path.closeSubpath()
        return path
    }

    private static func point(in rect: CGRect) -> (CGFloat, CGFloat) -> CGPoint {
        { x, y in CGPoint(x: rect.minX + x / 1024 * rect.width, y: rect.minY + y / 1024 * rect.height) }
    }
}

#if canImport(SwiftUI)
import SwiftUI

public extension BrandMark {
    struct Bookmark: Shape {
        public enum Kind: Sendable { case graphite, green }
        let kind: Kind

        public init(_ kind: Kind) { self.kind = kind }

        public func path(in rect: CGRect) -> Path {
            Path(kind == .green ? BrandMark.greenPath(in: rect) : BrandMark.graphitePath(in: rect))
        }
    }

    static var background: Color { Color(rgb: backgroundRGB) }
    static var graphite: Color { Color(rgb: graphiteRGB) }
    static var green: Color { Color(rgb: greenRGB) }
}

/// The app icon, drawn in SwiftUI (flat; the real icon adds Liquid Glass depth).
public struct BrandMarkIcon: View {
    let size: CGFloat

    public init(size: CGFloat) { self.size = size }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(BrandMark.background)
            .overlay {
                BrandMark.Bookmark(.graphite)
                    .fill(BrandMark.graphite)
                    .shadow(color: .black.opacity(0.18), radius: size * 0.02, y: size * 0.01)
                BrandMark.Bookmark(.green)
                    .fill(BrandMark.green.gradient)
                    .shadow(color: .black.opacity(0.22), radius: size * 0.025, y: size * 0.012)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
#endif
