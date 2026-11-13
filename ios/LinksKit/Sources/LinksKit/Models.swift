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

    public var initials: String {
        let letters = name.split(separator: " ").compactMap(\.first).prefix(2)
        return String(letters).uppercased()
    }
}

public struct SharedLink: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public var url: URL
    public var platform: Platform
    public var title: String?
    public var author: String?
    public var note: String
    public var thumb: String?
    public var meta: String
    public var addedBy: String
    public var addedAt: Date
    public var seen: [String: Date]
    public var reactions: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, url, platform, title, author, note, thumb, meta, seen, reactions
        case addedBy = "added_by"
        case addedAt = "added_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
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
        meta = try c.decodeIfPresent(String.self, forKey: .meta) ?? "done"
        addedBy = try c.decode(String.self, forKey: .addedBy)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
        reactions = try c.decodeIfPresent([String: String].self, forKey: .reactions) ?? [:]
    }

    public init(id: Int, url: URL, platform: Platform, title: String? = nil, author: String? = nil,
                note: String = "", thumb: String? = nil, meta: String = "done", addedBy: String,
                addedAt: Date = .now, seen: [String: Date] = [:], reactions: [String: String] = [:]) {
        self.id = id
        self.url = url
        self.platform = platform
        self.title = title
        self.author = author
        self.note = note
        self.thumb = thumb
        self.meta = meta
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.seen = seen
        self.reactions = reactions
    }

    public var isLoadingPreview: Bool { meta == "pending" }

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
    public var links: [SharedLink]

    public init(me: String, users: [LinkUser], links: [SharedLink]) {
        self.me = me
        self.users = users
        self.links = links
    }

    enum CodingKeys: String, CodingKey { case me, users, links }

    /// One bad row must not take down the whole inbox: undecodable users and links are skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        me = try c.decode(String.self, forKey: .me)
        users = try c.decode([Lossy<LinkUser>].self, forKey: .users).compactMap(\.value)
        links = try c.decode([Lossy<SharedLink>].self, forKey: .links).compactMap(\.value)
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

    func name(of id: String) -> String { user(id)?.name ?? "Someone" }

    var meUser: LinkUser? { user(me) }

    func isMine(_ link: SharedLink) -> Bool { link.addedBy == me }

    func isSeenByMe(_ link: SharedLink) -> Bool { link.seen[me] != nil }

    /// Not sent by me and not watched yet.
    func isUnwatched(_ link: SharedLink) -> Bool { !isMine(link) && !isSeenByMe(link) }

    var toWatch: [SharedLink] { links.filter(isUnwatched) }

    /// Names of people (not me, not the sender) who have watched it, earliest first.
    func seenByOthers(_ link: SharedLink) -> [String] {
        link.seen
            .filter { $0.key != me && $0.key != link.addedBy }
            .sorted { $0.value < $1.value }
            .map { name(of: $0.key) }
    }

    /// The people a new link goes to: everyone who has signed in, except me.
    var otherPeople: [LinkUser] { users.filter { $0.id != me && !$0.isLegacy } }

    func links(for filter: InboxFilter, matching query: String = "") -> [SharedLink] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return links.filter { link in
            switch filter {
            case .toWatch: guard isUnwatched(link) else { return false }
            case .watched: guard !isMine(link), isSeenByMe(link) else { return false }
            case .sent: guard isMine(link) else { return false }
            case .all: break
            }
            guard !words.isEmpty else { return true }
            let haystack = [link.title, link.author, link.note, name(of: link.addedBy),
                            link.url.absoluteString, link.platform.label]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

public struct MeResponse: Codable, Sendable {
    public var user: LinkUser
    public var claimable: [LinkUser]
}

public struct SignInResult: Codable, Sendable {
    public var token: String
    public var user: LinkUser
    public var claimable: [LinkUser]
}

public struct AddResult: Codable, Sendable {
    public var link: SharedLink
    public var duplicate: Bool
}

public let reactionEmojis = ["❤️", "😂", "🔥", "😮", "😭", "👎"]

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
