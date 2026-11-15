import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case tiktok, instagram, youtube, x, reddit, facebook, web

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Platform(rawValue: raw) ?? .web
    }

    /// Same rules as the server's platformOf().
    public init(host: String?) {
        let host = host?.lowercased() ?? ""
        let domains: [(Platform, [String])] = [
            (.tiktok, ["tiktok.com"]), (.instagram, ["instagram.com", "instagr.am"]),
            (.youtube, ["youtube.com", "youtu.be"]), (.x, ["x.com", "twitter.com"]),
            (.reddit, ["reddit.com", "redd.it"]), (.facebook, ["facebook.com", "fb.watch"]),
        ]
        self = domains.first { $0.1.contains { host == $0 || host.hasSuffix(".\($0)") } }?.0 ?? .web
    }

    public var label: String {
        switch self {
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        case .x: "X"
        case .reddit: "Reddit"
        case .facebook: "Facebook"
        case .web: "Link"
        }
    }

    public var noun: String {
        switch self {
        case .tiktok: "TikTok"
        case .instagram: "Instagram post"
        case .youtube: "YouTube video"
        case .x: "Post on X"
        case .reddit: "Reddit post"
        case .facebook: "Facebook post"
        case .web: "Link"
        }
    }

    /// Whatever opens it: the platform's app, or the browser for the rest of the web.
    public var opener: String { self == .web ? "Browser" : label }

    /// Short-video platforms, which a link page offers to watch rather than open.
    public var isVideo: Bool { [.tiktok, .instagram, .youtube].contains(self) }

    /// The main button on a link's page: "Watch in TikTok", "Open in Browser".
    public var openTitle: String { "\(isVideo ? "Watch" : "Open") in \(opener)" }

    /// Who owns the platform's name, for the trademark notice; nil for the open web.
    public var trademarkOwner: String? {
        switch self {
        case .tiktok: "ByteDance Ltd."
        case .instagram: "Instagram, LLC"
        case .youtube: "Google LLC"
        case .x: "X Corp."
        case .reddit: "Reddit, Inc."
        case .facebook: "Meta Platforms, Inc."
        case .web: nil
        }
    }

    /// The app names other companies' platforms, so it says whose trademarks they are and that
    /// Links isn't theirs. The sign-in screen and tour name only the two their copy mentions.
    public static func trademarkNotice(for platforms: [Platform] = allCases) -> String {
        let named = platforms.compactMap { platform in
            platform.trademarkOwner.map { owner in
                "\(platform.label) is a trademark of \(owner)\(owner.hasSuffix(".") ? "" : ".")"
            }
        }
        let them = named.count == 2 ? "either" : "any of them"
        return (named + ["Links isn't affiliated with or endorsed by \(them)."]).joined(separator: " ")
    }

    public static let shortTrademarkNotice = trademarkNotice(for: [.tiktok, .instagram])

    /// Text glyph for placeholder thumbnails.
    public var glyph: String {
        switch self {
        case .tiktok: "♪"
        case .instagram: "◎"
        case .youtube: "▶"
        case .x: "𝕏"
        case .reddit: "r/"
        case .facebook: "f"
        case .web: "🔗"
        }
    }
}

public struct LinkUser: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var avatar: URL?
    public var email: String?

    public init(id: String, name: String, avatar: URL? = nil, email: String? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.email = email
    }

    enum CodingKeys: String, CodingKey { case id, name, avatar, email }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // An empty or malformed avatar URL just means "no picture".
        avatar = try? c.decodeIfPresent(String.self, forKey: .avatar).flatMap(URL.webURL)
        email = try c.decodeIfPresent(String.self, forKey: .email)
    }

    /// Someone from before sign-in existed, waiting to be claimed.
    public var isLegacy: Bool { id.hasPrefix("legacy:") }

    /// The sender of links whose sender deleted their account (DELETED_USER in server/src/db.ts).
    /// It's never in `users`, so no new account can take those links over.
    public static let deletedID = "deleted"

    public var initials: String {
        let letters = name.split(separator: " ").compactMap(\.first).prefix(2)
        return String(letters).uppercased()
    }
}

/// A group chat (#12): its links are only for its members. Everyone starts in the default one.
public struct LinkGroup: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// Empty: the app names it after its members.
    public var name: String
    public var createdBy: String?
    public var createdAt: Date
    /// The chat everyone was in before chats, which new members join.
    public var isDefault: Bool
    /// User ids, oldest member first.
    public var members: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, members
        case createdBy = "created_by"
        case createdAt = "created_at"
        case isDefault = "default"
    }

    /// The thread its notifications and share sheet suggestions use: server/src/push.ts's thread-id.
    public var conversationID: String { isDefault ? Self.defaultConversationID : "links-group-\(id)" }
    public static let defaultConversationID = "links-inbox"

    public init(id: Int, name: String = "", createdBy: String? = nil, createdAt: Date = .now,
                isDefault: Bool = false, members: [String] = []) {
        self.id = id
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.isDefault = isDefault
        self.members = members
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
    }
}

public struct SharedLink: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// The chat it was sent to. Nil from servers (and cached inboxes) from before chats.
    public var groupID: Int?
    public var url: URL
    public var platform: Platform
    public var title: String?
    public var author: String?
    public var note: String
    public var thumb: String?
    /// Open Graph description: an article's standfirst, an Instagram post's like and comment counts.
    public var summary: String?
    /// The site's own name ("The Guardian"), or the platform's.
    public var siteName: String?
    /// The thumbnail's pixel size, when the server knows it.
    public var thumbWidth: Int?
    public var thumbHeight: Int?
    public var meta: String
    public var addedBy: String
    public var addedAt: Date
    public var seen: [String: Date]
    public var reactions: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, url, platform, title, author, note, thumb, meta, seen, reactions
        case summary = "description"
        case siteName = "site_name"
        case thumbWidth = "thumb_w"
        case thumbHeight = "thumb_h"
        case addedBy = "added_by"
        case addedAt = "added_at"
        case groupID = "group_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        groupID = try? c.decodeIfPresent(Int.self, forKey: .groupID)
        let raw = try c.decode(String.self, forKey: .url)
        guard let url = URL.webURL(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "Unusable URL \(raw)")
        }
        self.url = url
        platform = try c.decode(Platform.self, forKey: .platform)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        thumbWidth = try? c.decodeIfPresent(Int.self, forKey: .thumbWidth)
        thumbHeight = try? c.decodeIfPresent(Int.self, forKey: .thumbHeight)
        meta = try c.decodeIfPresent(String.self, forKey: .meta) ?? "done"
        addedBy = try c.decode(String.self, forKey: .addedBy)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
        reactions = try c.decodeIfPresent([String: String].self, forKey: .reactions) ?? [:]
    }

    public init(id: Int, groupID: Int? = nil, url: URL, platform: Platform, title: String? = nil, author: String? = nil,
                note: String = "", thumb: String? = nil, summary: String? = nil, siteName: String? = nil,
                thumbWidth: Int? = nil, thumbHeight: Int? = nil, meta: String = "done", addedBy: String,
                addedAt: Date = .now, seen: [String: Date] = [:], reactions: [String: String] = [:]) {
        self.id = id
        self.groupID = groupID
        self.url = url
        self.platform = platform
        self.title = title
        self.author = author
        self.note = note
        self.thumb = thumb
        self.summary = summary
        self.siteName = siteName
        self.thumbWidth = thumbWidth
        self.thumbHeight = thumbHeight
        self.meta = meta
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.seen = seen
        self.reactions = reactions
    }

    public var isLoadingPreview: Bool { meta == "pending" }

    /// The server tried and found nothing to show; the app offers a retry.
    public var previewFailed: Bool { meta == "failed" }

    /// The `<v>` of a `/thumbs/<id>/<v>` thumbnail URL, which the server bumps when it replaces the image.
    public var thumbVersion: String? {
        guard let parts = thumb?.split(separator: "/"), parts.count == 3 else { return nil }
        return String(parts[2])
    }

    /// Width over height of the thumbnail, clamped to what a card can show (9:16 portrait to 2:1 wide).
    /// Without a known size, short-video platforms are assumed portrait and the web landscape.
    public var thumbAspect: Double {
        if let w = thumbWidth, let h = thumbHeight, w > 0, h > 0 {
            return min(max(Double(w) / Double(h), 9.0 / 16.0), 2)
        }
        switch platform {
        case .tiktok, .instagram: return 9.0 / 16.0
        case .youtube: return 16.0 / 9.0
        default: return 1.91
        }
    }

    /// Tall cards (reels, TikToks) are shown narrower, as Messages does.
    public var isPortrait: Bool { thumbAspect < 1 }

    /// The domain without "www.", as Messages shows under a link.
    public var host: String {
        url.host()?.replacingOccurrences(of: "www.", with: "", options: .anchored) ?? url.absoluteString
    }

    /// Where it's from, for the card's footer: the site's name, else the platform or the domain.
    public var sourceName: String {
        if let siteName, !siteName.isEmpty { return siteName }
        return platform == .web ? host : platform.label
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        switch platform {
        case .web:
            return url.host()?.replacingOccurrences(of: "www.", with: "", options: .anchored) ?? "Link"
        case .instagram where url.path().contains("/reel/"):
            return "Instagram reel"
        default:
            return platform.noun
        }
    }
}

public struct InboxState: Codable, Sendable, Hashable {
    public var me: String
    public var users: [LinkUser]
    /// The chats I'm in, the default one first, then oldest first.
    public var groups: [LinkGroup]
    public var links: [SharedLink]
    /// The people I've blocked. The server already leaves out their links, seen marks and
    /// reactions; they stay in `users` so Blocked People can name them.
    public var blocked: [String]

    public init(me: String, users: [LinkUser], groups: [LinkGroup] = [], links: [SharedLink], blocked: [String] = []) {
        self.me = me
        self.users = users
        self.groups = groups
        self.links = links
        self.blocked = blocked
    }

    enum CodingKeys: String, CodingKey { case me, users, groups, links, blocked }

    /// One bad row must not take down the whole inbox: undecodable users and links are skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        me = try c.decode(String.self, forKey: .me)
        users = try c.decode([Lossy<LinkUser>].self, forKey: .users).compactMap(\.value)
        // Servers and cached snapshots from before chats have no `groups`.
        groups = try c.decodeIfPresent([Lossy<LinkGroup>].self, forKey: .groups)?.compactMap(\.value) ?? []
        links = try c.decode([Lossy<SharedLink>].self, forKey: .links).compactMap(\.value)
        // Older servers and cached snapshots have no `blocked`.
        blocked = try c.decodeIfPresent([String].self, forKey: .blocked) ?? []
    }

    public static let empty = InboxState(me: "", users: [], links: [])
}

public enum InboxFilter: String, CaseIterable, Sendable, Identifiable {
    case toWatch, watched, sent, all
    public var id: Self { self }

    public var title: String {
        switch self {
        case .toWatch: "To Watch"
        case .watched: "Watched"
        case .sent: "Sent"
        case .all: "All Links"
        }
    }
}

public extension InboxState {
    func user(_ id: String) -> LinkUser? { users.first { $0.id == id } }

    func name(of id: String) -> String {
        user(id)?.name ?? (id == LinkUser.deletedID ? "Deleted user" : "Someone")
    }

    var meUser: LinkUser? { user(me) }

    func isMine(_ link: SharedLink) -> Bool { link.addedBy == me }

    func isSeenByMe(_ link: SharedLink) -> Bool { link.seen[me] != nil }

    /// Not sent by me and not watched yet.
    func isUnwatched(_ link: SharedLink) -> Bool { !isMine(link) && !isSeenByMe(link) }

    var toWatch: [SharedLink] { links.filter(isUnwatched) }

    /// The one list of To Watch, Watched and Sent that has this link.
    func home(of link: SharedLink) -> InboxFilter {
        isMine(link) ? .sent : isSeenByMe(link) ? .watched : .toWatch
    }

    /// Names of people (not me, not the sender) who have watched it, earliest first.
    func seenByOthers(_ link: SharedLink) -> [String] {
        link.seen
            .filter { $0.key != me && $0.key != link.addedBy }
            .sorted { $0.value < $1.value }
            .map { name(of: $0.key) }
    }

    /// The people the server lists for me (those I share a chat with), except me: who a new chat can have in it.
    /// `users` also has senders of links I can still see, after they've left all my chats: those
    /// aren't people I share a chat with. Servers from before chats have no chats to go by.
    var otherPeople: [LinkUser] {
        let members = Set(groups.flatMap(\.members))
        return users.filter { $0.id != me && !$0.isLegacy && (groups.isEmpty || members.contains($0.id)) }
    }

    // MARK: Chats

    func group(_ id: Int?) -> LinkGroup? { id.flatMap { id in groups.first { $0.id == id } } }

    /// The chat a notification thread or share sheet suggestion is for.
    func group(conversationID: String?) -> LinkGroup? {
        guard let conversationID else { return nil }
        return groups.first { $0.conversationID == conversationID }
    }

    /// The chat everyone starts in, if I'm still in it.
    var defaultGroup: LinkGroup? { groups.first(where: \.isDefault) }

    /// More than one chat: only then do the lists, sheets and widgets say which chat a link is in.
    var hasChats: Bool { groups.count > 1 }

    /// Other people in a chat who are still in Links, oldest member first.
    func otherMembers(of group: LinkGroup) -> [LinkUser] {
        group.members.compactMap { id in id == me ? nil : user(id) }.filter { !$0.isLegacy }
    }

    /// Who a link sent to this chat goes to. Without a chat (servers from before chats), everyone.
    func recipients(in group: LinkGroup?) -> [LinkUser] {
        guard let group else { return otherPeople }
        return otherMembers(of: group)
    }

    /// The people a link went to besides its sender: its chat's members.
    func recipients(of link: SharedLink) -> [LinkUser] {
        recipients(in: group(link.groupID)).filter { $0.id != link.addedBy }
    }

    /// A chat's name, or, like Messages, its members' names when nobody has named it.
    func title(of group: LinkGroup) -> String {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if group.isDefault { return "Everyone" }
        let others = otherMembers(of: group).map(\.name)
        return others.isEmpty ? "Just You" : LinkFormat.names(others)
    }

    /// The chat a new link goes to unless I pick another: the default one, else my first.
    var preferredGroup: LinkGroup? { defaultGroup ?? groups.first }

    /// The chat the Share Extension starts on. Without a share-sheet suggestion, `preferredGroup`.
    /// From one (`conversationID`, as ShareSuggestions donated it), that chat; if I've since left it
    /// (e.g. on another device), my only chat, else `nil`, so I pick rather than send it elsewhere.
    func shareGroup(fromSuggestion: Bool, conversationID: String? = nil) -> LinkGroup? {
        guard fromSuggestion, !groups.isEmpty else { return preferredGroup }
        return group(conversationID: conversationID) ?? (groups.count == 1 ? groups[0] : nil)
    }

    /// People I know who aren't in this chat yet and whom I haven't blocked, to add.
    func addable(to group: LinkGroup) -> [LinkUser] {
        otherPeople.filter { !group.members.contains($0.id) && !isBlocked($0.id) }
    }

    /// Links in one chat; `nil` is all of them.
    func links(in groupID: Int?) -> [SharedLink] {
        guard let groupID else { return links }
        return links.filter { $0.groupID == groupID }
    }

    /// What the server shows once I've left a chat: none of its links.
    func leaving(group id: Int) -> InboxState {
        var state = self
        state.groups.removeAll { $0.id == id }
        state.links.removeAll { $0.groupID == id }
        return state
    }

    /// The server's copy of a chat I'm in, new or changed.
    func updating(_ group: LinkGroup) -> InboxState {
        var state = self
        if let i = state.groups.firstIndex(where: { $0.id == group.id }) {
            state.groups[i] = group
        } else {
            state.groups.append(group)
        }
        return state
    }

    func isBlocked(_ id: String) -> Bool { blocked.contains(id) }

    /// Blocked People, in the order I blocked them.
    var blockedPeople: [LinkUser] { blocked.compactMap(user) }

    /// Someone else who's still in Links (not "Deleted user") and not blocked already.
    func canBlock(_ id: String) -> Bool { id != me && user(id) != nil && !isBlocked(id) }

    /// What the server shows once I've reported a link: the same, without it.
    func hiding(link id: Int) -> InboxState {
        var state = self
        state.links.removeAll { $0.id == id }
        return state
    }

    /// What the server shows once I've blocked someone: none of their links, marks or reactions.
    func blocking(_ id: String) -> InboxState {
        var state = self
        if !state.blocked.contains(id) { state.blocked.append(id) }
        state.links = links.filter { $0.addedBy != id }.map { link in
            var link = link
            link.seen[id] = nil
            link.reactions[id] = nil
            return link
        }
        return state
    }

    func unblocking(_ id: String) -> InboxState {
        var state = self
        state.blocked.removeAll { $0 == id }
        return state
    }

    /// One list's links, in one chat (`nil`: every chat), matching a search.
    func links(for filter: InboxFilter, in groupID: Int? = nil, matching query: String = "") -> [SharedLink] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return links.filter { link in
            if let groupID, link.groupID != groupID { return false }
            switch filter {
            case .toWatch: guard isUnwatched(link) else { return false }
            case .watched: guard !isMine(link), isSeenByMe(link) else { return false }
            case .sent: guard isMine(link) else { return false }
            case .all: break
            }
            guard !words.isEmpty else { return true }
            let haystack = [link.title, link.author, link.note, name(of: link.addedBy),
                            link.url.absoluteString, link.platform.label, group(link.groupID).map(title(of:))]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

public struct MeResponse: Codable, Sendable {
    public var user: LinkUser
    public var claimable: [LinkUser]
}

/// An invite I sent that nobody has used yet (GET /api/invites).
public struct Invite: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// Who it's for, if I said: that verified address gets in even without the link.
    public var email: String?
    public var createdAt: Date
    public var expiresAt: Date
    /// Only in the reply that made it: the server keeps just a hash of the token.
    public var url: URL?

    enum CodingKeys: String, CodingKey {
        case id, email, url
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

public struct SignInResult: Codable, Sendable {
    public var token: String
    public var user: LinkUser
    public var claimable: [LinkUser]
}

public struct GroupEnvelope: Codable, Sendable {
    public var group: LinkGroup
}

public struct AddResult: Codable, Sendable {
    public var link: SharedLink
    public var duplicate: Bool
}

public let reactionEmojis = ["❤️", "😂", "🔥", "😮", "😭", "👎"]

/// Why something was reported (REPORT_REASONS in server/src/moderation.ts).
public enum ReportReason: String, CaseIterable, Sendable, Identifiable {
    case spam, offensive, harassment, other
    public var id: Self { self }

    public var title: String {
        switch self {
        case .spam: "Spam"
        case .offensive: "Offensive or Inappropriate"
        case .harassment: "Harassment or Bullying"
        case .other: "Something Else"
        }
    }
}

/// Decodes an element if it can, or yields nil instead of failing the whole array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension URL {
    /// Parses an http(s) URL without "repairing" it: Foundation's lenient parser would re-escape
    /// valid %XX sequences in a path that also has a character it dislikes, changing the link.
    static func webURL(_ string: String) -> URL? {
        guard !string.isEmpty else { return nil }
        return URL(string: string, encodingInvalidCharacters: false) ?? URL(string: string)
    }
}
