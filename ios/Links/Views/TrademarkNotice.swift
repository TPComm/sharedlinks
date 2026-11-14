import LinksKit
import SwiftUI

/// Small print saying whose trademarks TikTok and Instagram are, where the app first names them
/// (sign-in and the tour). About Links in the account menu has the full list.
struct TrademarkNotice: View {
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(Platform.shortTrademarkNotice)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
            .accessibilityIdentifier("trademarkNotice")
    }
}
