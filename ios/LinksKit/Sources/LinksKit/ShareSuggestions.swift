import Foundation

public enum AvatarPalette {
    /// iOS system colors, as RGB hex, in the order the old web app used.
    public static let hex: [UInt32] = [0xFF9500, 0x34C759, 0x5856D6, 0xFF2D55, 0x00C7BE, 0xAF52DE, 0x007AFF, 0xFF3B30]

    /// Stable color for a name (same hash as the web app, so people keep their color).
    public static func index(for name: String) -> Int {
        var h: UInt32 = 0
        for scalar in name.unicodeScalars { h = h &* 31 &+ scalar.value }
        return Int(h % UInt32(hex.count))
    }
}

#if os(iOS)
import Intents
import UIKit

/// Share sheet suggestions. Each time you send a link we donate an `INSendMessageIntent`
/// for the shared inbox, and iOS starts offering it in the share sheet's top row (the one
/// with people from Messages) with the Links badge on it. Tapping it opens the Share
/// Extension, which already knows where the link is going.
public enum ShareSuggestions {
    public static let conversationID = "links-inbox"

    public static func donateSend(in state: InboxState) {
        let others = state.otherPeople
        guard !others.isEmpty else { return }
        let recipients = others.map { person(for: $0, isMe: false) }
        let groupName = others.count > 1
            ? INSpeakableString(spokenPhrase: LinkFormat.names(others.map(\.name))) : nil
        let intent = INSendMessageIntent(
            recipients: recipients, outgoingMessageType: .outgoingMessageText, content: nil,
            speakableGroupName: groupName, conversationIdentifier: conversationID, serviceName: nil,
            sender: state.meUser.map { person(for: $0, isMe: true) }, attachments: nil)
        if groupName != nil {
            intent.setImage(groupImage(), forParameterNamed: \.speakableGroupName)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate(completion: nil)
    }

    /// Forget donations, e.g. on sign-out.
    public static func deleteAll() {
        INInteraction.deleteAll(completion: nil)
    }

    static func person(for user: LinkUser, isMe: Bool) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: user.id, type: .unknown), nameComponents: nil,
                 displayName: user.name, image: avatarImage(for: user), contactIdentifier: nil,
                 customIdentifier: user.id, isMe: isMe)
    }

    static func avatarImage(for user: LinkUser) -> INImage? {
        let hex = AvatarPalette.hex[AvatarPalette.index(for: user.name)]
        let color = UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        return render { rect in
            color.setFill()
            UIBezierPath(ovalIn: rect).fill()
            let text = user.initials as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: rect.width * 0.4, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
    }

    static func groupImage() -> INImage? {
        render { rect in
            UIBezierPath(ovalIn: rect).addClip()
            uiColor(BrandMark.backgroundRGB).setFill()
            UIRectFill(rect)
            // The mark fills the icon square edge to edge; inset it so it sits inside the circle.
            let mark = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
            uiColor(BrandMark.graphiteRGB).setFill()
            UIBezierPath(cgPath: BrandMark.graphitePath(in: mark)).fill()
            uiColor(BrandMark.greenRGB).setFill()
            UIBezierPath(cgPath: BrandMark.greenPath(in: mark)).fill()
        }
    }

    static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func render(_ draw: (CGRect) -> Void) -> INImage? {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 120)
        let image = UIGraphicsImageRenderer(size: rect.size).image { _ in draw(rect) }
        return image.pngData().map { INImage(imageData: $0) }
    }
}
#endif
