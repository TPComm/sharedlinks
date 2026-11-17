import Foundation

/// What a new-link push carries for the Notification Service Extension and the app's actions
/// (`Pusher.newLink` in server/src/push.ts).
public struct LinkNotification: Equatable, Sendable {
    /// The category the server sets on new-link pushes, which the app registers its actions under.
    public static let category = "NEW_LINK"
    public static let markSeenAction = "MARK_SEEN"
    public static let commentAction = "COMMENT"

    public var linkID: Int
    public var groupID: Int?
    public var senderID: String?
    public var senderName: String?
    public var senderAvatar: URL?
    /// The chat's name, for a named chat other than the default one.
    public var chat: String?
    /// The thumbnail's path on the server (`/thumbs/<id>/<v>`), fetched with the phone's session.
    public var thumb: String?

    public init(linkID: Int, groupID: Int? = nil, senderID: String? = nil, senderName: String? = nil,
                senderAvatar: URL? = nil, chat: String? = nil, thumb: String? = nil) {
        self.linkID = linkID
        self.groupID = groupID
        self.senderID = senderID
        self.senderName = senderName
        self.senderAvatar = senderAvatar
        self.chat = chat
        self.thumb = thumb
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let linkID = Self.int(userInfo["link_id"]) else { return nil }
        self.linkID = linkID
        groupID = Self.int(userInfo["group_id"])
        senderID = Self.text(userInfo["sender_id"])
        senderName = Self.text(userInfo["sender_name"])
        senderAvatar = Self.text(userInfo["sender_avatar"]).flatMap(URL.init(string:))
            .flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? $0 : nil }
        chat = Self.text(userInfo["chat"])
        // Only a path on our own server: the session token goes with it.
        thumb = Self.text(userInfo["thumb"]).flatMap { $0.hasPrefix("/thumbs/") && !$0.contains("..") ? $0 : nil }
    }

    /// The conversation the push belongs to, the same id `ShareSuggestions` donates for the chat.
    public var conversationID: String {
        if let groupID, chat != nil { return "links-group-\(groupID)" }
        return LinkGroup.defaultConversationID
    }

    /// A file extension iOS accepts for a notification attachment of this image type.
    public static func fileExtension(forContentType type: String?) -> String? {
        switch type?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/heic": "heic"
        case "image/webp": "webp"
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func text(_ value: Any?) -> String? {
        guard let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
