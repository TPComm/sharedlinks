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
/// for the chat it went to, and iOS starts offering that chat in the share sheet's top row (the
/// one with people from Messages) with the Links badge on it. Tapping it opens the Share
/// Extension, which reads the chat from the intent's conversation identifier.
public enum ShareSuggestions {
    /// The default chat's conversation, the one from before chats; other chats use `links-group-<id>`.
    public static let conversationID = LinkGroup.defaultConversationID

    /// Donates the chat a link was just sent to: `nil` is the default chat (or, on a server from
    /// before chats, everyone).
    public static func donateSend(in state: InboxState, groupID: Int? = nil) {
        let group = state.group(groupID) ?? state.preferredGroup
        let others = state.recipients(in: group)
        guard !others.isEmpty else { return }
        let id = group?.conversationID ?? conversationID
        let named = group.map { !$0.isDefault && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        let groupName = others.count > 1 || named || group?.isDefault == true
            ? INSpeakableString(spokenPhrase: group.map(state.title(of:)) ?? LinkFormat.names(others.map(\.name)))
            : nil
        let intent = INSendMessageIntent(
            recipients: others.map { person(for: $0, isMe: false) }, outgoingMessageType: .outgoingMessageText,
            content: nil, speakableGroupName: groupName, conversationIdentifier: id, serviceName: nil,
            sender: state.meUser.map { person(for: $0, isMe: true) }, attachments: nil)
        if groupName != nil {
            intent.setImage(groupImage(), forParameterNamed: \.speakableGroupName)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = id
        interaction.donate(completion: nil)
    }

    static let seededKey = "links.shareSuggestions.seededChats"
    static let legacySeededKey = "links.shareSuggestions.seeded"

    /// Donates each chat once, as soon as someone else is in it, rather than waiting for the first
    /// send (#9): the share sheet can then start suggesting it sooner. iOS decides when a donated
    /// conversation appears; this only starts the clock.
    public static func seedIfNeeded(in state: InboxState) {
        let defaults = LinksConfig.sharedDefaults
        var seeded = Set(defaults.stringArray(forKey: seededKey) ?? [])
        if defaults.bool(forKey: legacySeededKey) { seeded.insert(conversationID) }
        let chats: [LinkGroup?] = state.groups.isEmpty ? [nil] : state.groups
        var changed = false
        for group in chats {
            let id = group?.conversationID ?? conversationID
            guard !seeded.contains(id), !state.recipients(in: group).isEmpty else { continue }
            seeded.insert(id)
            changed = true
            donateSend(in: state, groupID: group?.id)
        }
        if changed { defaults.set(seeded.sorted(), forKey: seededKey) }
    }

    /// Forget a chat I've left, so the share sheet stops offering it.
    public static func forget(_ group: LinkGroup) {
        INInteraction.delete(with: group.conversationID, completion: nil)
        let defaults = LinksConfig.sharedDefaults
        let seeded = (defaults.stringArray(forKey: seededKey) ?? []).filter { $0 != group.conversationID }
        defaults.set(seeded, forKey: seededKey)
    }

    /// Forget donations, e.g. on sign-out.
    public static func deleteAll() {
        INInteraction.deleteAll(completion: nil)
        LinksConfig.sharedDefaults.removeObject(forKey: seededKey)
        LinksConfig.sharedDefaults.removeObject(forKey: legacySeededKey)
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
