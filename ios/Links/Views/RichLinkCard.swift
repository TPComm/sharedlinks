import LinksKit
import SwiftUI

/// A link as Messages shows one: the image at its own shape (a reel stays tall, an article wide),
/// then the title or caption, the description, and where it's from. The image's space is set by
/// the size the server reported before the image loads, so nothing moves when it arrives.
struct RichLinkCard: View {
    let link: SharedLink

    var body: some View {
        Group {
            if link.thumb != nil || link.isLoadingPreview {
                VStack(alignment: .leading, spacing: 0) {
                    ThumbnailView(link: link, cornerRadius: 0)
                        .aspectRatio(link.thumbAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    text.padding(.horizontal, 12).padding(.vertical, 10)
                }
            } else {
                // No image (a plain page, or the preview failed): a compact bar, as Messages does.
                HStack(spacing: 10) {
                    ThumbnailImage(platform: link.platform, image: nil, cornerRadius: 8)
                        .frame(width: 44, height: 44)
                    text
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .contentShape(.rect(cornerRadius: 18, style: .continuous))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            if link.isLoadingPreview {
                Text("Loading preview title").redacted(reason: .placeholder)
                    .font(.subheadline.weight(.semibold))
            } else {
                Text(link.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(4)
            }
            if link.previewFailed {
                Text("No preview available")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let summary = link.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(source)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "@handle · Instagram", "The Guardian", "example.com".
    private var source: String {
        let site = link.sourceName
        guard let author = link.author, !author.isEmpty, author != site else { return site }
        return "\(author) · \(site)"
    }
}
