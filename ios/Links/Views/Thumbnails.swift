import LinksKit
import SwiftUI

/// Decoded thumbnails, in memory, on top of LinksKit's on-disk cache (shared with the widget).
@MainActor
enum ThumbnailCache {
    private static let images = NSCache<NSNumber, UIImage>()

    static func cachedImage(for link: SharedLink) -> UIImage? {
        if let image = images.object(forKey: link.id as NSNumber) { return image }
        guard let data = ThumbnailStore.cached(link.id), let image = UIImage(data: data) else { return nil }
        images.setObject(image, forKey: link.id as NSNumber)
        return image
    }

    /// On sign-out, with the files under it (InboxSnapshot.clear).
    static func clear() { images.removeAllObjects() }

    static func image(for link: SharedLink, client: APIClient) async -> UIImage? {
        if let image = cachedImage(for: link) { return image }
        guard let data = await ThumbnailStore.shared.data(for: link, client: client),
              let image = UIImage(data: data) else { return nil }
        images.setObject(image, forKey: link.id as NSNumber)
        return image
    }
}

struct ThumbnailView: View {
    @Environment(AppModel.self) private var model
    let link: SharedLink
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?

    var body: some View {
        // The flexible base takes the frame the caller gives; overlays (including a landscape
        // image scaled to fill) are then clipped to it.
        ThumbnailImage(platform: link.platform, image: image, cornerRadius: cornerRadius)
            .overlay {
                if image != nil, link.platform != .web {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.35), in: .circle)
                }
            }
            .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: link.thumb) {
            image = ThumbnailCache.cachedImage(for: link)
            guard image == nil, link.thumb != nil else { return }
            image = await ThumbnailCache.image(for: link, client: model.client)
        }
        .accessibilityHidden(true)
    }
}

struct AvatarView: View {
    let user: LinkUser?
    var size: CGFloat = 30

    var body: some View {
        let name = user?.name ?? "?"
        let hex = AvatarPalette.hex[AvatarPalette.index(for: name)]
        let color = Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                          blue: Double(hex & 0xFF) / 255)
        ZStack {
            Circle().fill(color.gradient)
            Text(user?.initials ?? "")
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let url = user?.avatar {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipShape(.circle)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
