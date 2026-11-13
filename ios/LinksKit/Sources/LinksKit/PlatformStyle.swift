#if canImport(UIKit)
import SwiftUI
import UIKit

/// Platform colors shared by the app, the Share Extension and the widget.
public extension Platform {
    private static let instagramGradient = LinearGradient(
        colors: [Color(hex: 0xFEDA75), Color(hex: 0xFA7E1E), Color(hex: 0xD62976), Color(hex: 0x962FBF), Color(hex: 0x4F5BD5)],
        startPoint: .bottomLeading, endPoint: .topTrailing)

    /// Fills the thumbnail slot when there's no image.
    var placeholderStyle: AnyShapeStyle {
        switch self {
        case .tiktok:
            AnyShapeStyle(LinearGradient(stops: [.init(color: Color(hex: 0x25F4EE), location: 0),
                                                 .init(color: .black, location: 0.45),
                                                 .init(color: .black, location: 0.55),
                                                 .init(color: Color(hex: 0xFE2C55), location: 1)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
        case .instagram: AnyShapeStyle(Self.instagramGradient)
        case .youtube: AnyShapeStyle(Color(hex: 0xFF0000))
        case .reddit: AnyShapeStyle(Color(hex: 0xFF4500))
        case .facebook: AnyShapeStyle(Color(hex: 0x1877F2))
        case .x, .web: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x8E8E93), Color(hex: 0x48484A)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    /// Background of the small platform label.
    var badgeStyle: AnyShapeStyle {
        switch self {
        case .tiktok: AnyShapeStyle(Color(light: .black, dark: Color(hex: 0xFE2C55)))
        case .instagram: AnyShapeStyle(Self.instagramGradient)
        case .youtube: AnyShapeStyle(Color(hex: 0xFF0000))
        case .reddit: AnyShapeStyle(Color(hex: 0xFF4500))
        case .facebook: AnyShapeStyle(Color(hex: 0x1877F2))
        case .x, .web: AnyShapeStyle(Color(hex: 0x8E8E93))
        }
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }

    /// The app's pink-to-purple brand gradient colors.
    static let linksPink = Color(red: 1, green: 0.22, blue: 0.37)
    static let linksPurple = Color(red: 0.47, green: 0.24, blue: 0.86)
}

/// A link's thumbnail (or its platform placeholder), as used in lists and widgets.
public struct ThumbnailImage: View {
    let platform: Platform
    let image: UIImage?
    let cornerRadius: CGFloat

    public init(platform: Platform, image: UIImage?, cornerRadius: CGFloat = 10) {
        self.platform = platform
        self.image = image
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        // Rectangle is flexible, so it takes exactly the frame it's given. The overlays size to
        // it, and a scaled-to-fill image is clipped to it instead of spilling out.
        Rectangle()
            .fill(platform.placeholderStyle)
            .overlay {
                Text(platform.glyph)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}
#endif
