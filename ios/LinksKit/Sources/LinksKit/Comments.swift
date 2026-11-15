import Foundation

public struct LinkComment: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let linkID: Int
    public let person: String
    public let body: String
    public let createdAt: Date
    public let editedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, person, body
        case linkID = "link_id"
        case createdAt = "created_at"
        case editedAt = "edited_at"
    }

    public static let bodyLimit = 1_000

    public static func isValidBody(_ body: String) -> Bool {
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.unicodeScalars.count <= bodyLimit
    }
}

public struct CommentActivity: Codable, Sendable, Hashable {
    public let person: String
    public let snippet: String
    public let at: Date
}

/// Read positions belong to an account and server, not to whoever next signs in on this phone.
public struct CommentReadState: Codable, Sendable {
    private var positions: [String: [String: Date]] = [:]
    private static let key = "commentReadState"

    public init() {}

    private func scope(_ person: String, _ server: URL) -> String {
        "\(server.absoluteString)|\(person)"
    }

    public func hasUnread(_ link: SharedLink, person: String, server: URL) -> Bool {
        guard link.commentCount > 0, let last = link.lastComment, last.person != person else { return false }
        return last.at > (positions[scope(person, server)]?[String(link.id)] ?? .distantPast)
    }

    public mutating func markRead(_ linkID: Int, through date: Date, person: String, server: URL) {
        let key = scope(person, server)
        let id = String(linkID)
        positions[key, default: [:]][id] = max(positions[key]?[id] ?? .distantPast, date)
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key) else { return Self() }
        return (try? APIClient.decoder.decode(Self.self, from: data)) ?? Self()
    }

    public func save(defaults: UserDefaults = .standard) {
        guard let data = try? APIClient.encoder.encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
