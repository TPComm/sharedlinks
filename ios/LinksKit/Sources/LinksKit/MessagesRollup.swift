import Foundation

public struct MessagesRollupSelection: Sendable, Hashable {
    public let groupID: String
    public let tokens: [String]

    public init?(url: URL?, associatedDomain: String? = LinksConfig.associatedDomain) {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        guard let page = components.url,
              case .group(let id) = DeepLink(url: page, associatedDomain: associatedDomain),
              let raw = components.queryItems?.first(where: { $0.name == "links" })?.value else { return nil }
        groupID = id
        var seen = Set<String>()
        tokens = raw.split(separator: ",").map(String.init).filter { DeepLink.isToken($0) && seen.insert($0).inserted }
    }

    public func links(in state: InboxState) -> [SharedLink] {
        tokens.compactMap { token in state.links.first { $0.token == token && String($0.groupID ?? -1) == groupID } }
    }
}

public struct MessagesRollup: Sendable, Hashable, Identifiable {
    public let id: Int
    public let chatName: String
    public let links: [SharedLink]

    private static func shareToken(_ link: SharedLink) -> String? {
        guard let url = link.shareURL, url.absoluteString.count <= 5000,
              ["http", "https"].contains(url.scheme?.lowercased()),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "l", DeepLink.isToken(parts[1]) else { return nil }
        return parts[1]
    }

    public var caption: String { "\(links.count) \(links.count == 1 ? "link" : "links") from today" }
    public var detail: String { "\(links.count) \(links.count == 1 ? "link" : "links") to \(chatName)" }
    public var subcaption: String {
        let titles = links.prefix(2).map { String($0.displayTitle.prefix(50)) }
        let summary = titles.joined(separator: ", ")
        return links.count > 2 ? "\(summary) and \(links.count - 2) more" : summary
    }

    public func url(associatedDomain: String? = LinksConfig.associatedDomain) -> URL? {
        guard let associatedDomain else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = associatedDomain
        components.path = "/g/\(id)"
        var tokens: [String] = []
        for link in links {
            guard let token = Self.shareToken(link) else { continue }
            components.queryItems = [URLQueryItem(name: "links", value: (tokens + [token]).joined(separator: ","))]
            guard let url = components.url, url.absoluteString.count <= 5000 else { break }
            tokens.append(token)
        }
        guard !tokens.isEmpty else { return nil }
        components.queryItems = [URLQueryItem(name: "links", value: tokens.joined(separator: ","))]
        return components.url
    }

    public static func today(in state: InboxState, now: Date = .now, calendar: Calendar = .current) -> [Self] {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        return state.groups.compactMap { group -> Self? in
            let links = state.links.filter {
                $0.groupID == group.id && state.isMine($0) && $0.addedAt >= day.start && $0.addedAt < day.end
                    && Self.shareToken($0) != nil
            }.sorted { $0.addedAt == $1.addedAt ? $0.id > $1.id : $0.addedAt > $1.addedAt }
            return links.isEmpty ? nil : Self(id: group.id, chatName: state.title(of: group), links: links)
        }.sorted {
            if $0.links[0].addedAt == $1.links[0].addedAt { return $0.id < $1.id }
            return $0.links[0].addedAt > $1.links[0].addedAt
        }
    }
}

public struct MessagesRollupInsertion: Sendable {
    private let token: String
    private let user: LinkUser
    private let rollup: MessagesRollup

    public init?(rollup: MessagesRollup, token: String?, currentUser: LinkUser?) {
        guard let token, let currentUser else { return nil }
        self.token = token
        user = currentUser
        self.rollup = rollup
    }

    public func canInsert(token: String?, currentUser: LinkUser?, conversationMatches: Bool,
                          rollups: [MessagesRollup]) -> Bool {
        token == self.token && currentUser == user && conversationMatches && rollups.contains(rollup)
    }
}
