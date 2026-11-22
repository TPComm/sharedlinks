import Foundation
import Observation

public enum MessagesSelection {
    public static func token(for url: URL?, associatedDomain: String? = LinksConfig.associatedDomain) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        guard let page = components.url,
              case .link(let token) = DeepLink(url: page, associatedDomain: associatedDomain) else { return nil }
        return token
    }
}

public struct MessagesInsertion: Sendable {
    private let token: String
    private let user: LinkUser
    private let linkID: Int
    private let shareURL: URL

    public init?(row: MessagesPickerRow, token: String?, currentUser: LinkUser?) {
        guard let token, let currentUser, let url = row.payload.url else { return nil }
        self.token = token
        user = currentUser
        linkID = row.id
        shareURL = url
    }

    public func canInsert(token: String?, currentUser: LinkUser?, conversationMatches: Bool,
                          state: MessagesPickerState) -> Bool {
        guard token == self.token, currentUser == user, conversationMatches,
              case .loaded(let content, _) = state else { return false }
        return content.sections.contains { section in
            section.rows.contains { $0.id == linkID && $0.payload.url == shareURL }
        }
    }
}

public struct MessagesPayload: Sendable, Hashable {
    public let caption: String
    public let subcaption: String
    public let url: URL?

    public init(link: SharedLink) {
        caption = link.displayTitle
        subcaption = "Sent with Links"
        url = link.shareURL.flatMap {
            guard ["http", "https"].contains($0.scheme?.lowercased()),
                  $0.host?.isEmpty == false, $0.absoluteString.count <= 5000 else { return nil }
            return $0
        }
    }
}

public struct MessagesPickerRow: Sendable, Hashable, Identifiable {
    public let link: SharedLink
    public let sender: String
    public var id: Int { link.id }
    public var payload: MessagesPayload { MessagesPayload(link: link) }
    public var canSend: Bool { payload.url != nil }
    public var guidance: String? { canSend ? nil : "Open Links to refresh this link" }

    public init(link: SharedLink, sender: String = "Someone") {
        self.link = link
        self.sender = sender
    }
}

public struct MessagesPickerSection: Sendable, Hashable, Identifiable {
    public let title: String
    public let rows: [MessagesPickerRow]
    public var id: String { title }
}

public struct MessagesPickerContent: Sendable, Hashable {
    public let inbox: InboxState
    public var rollups: [MessagesRollup] { MessagesRollup.today(in: inbox) }
    public let sections: [MessagesPickerSection]
    public var isEmpty: Bool { sections.isEmpty }

    public init(state: InboxState, recentLimit: Int = 20) {
        inbox = state
        let queue = state.links(for: .toWatch)
        let queued = Set(queue.map(\.id))
        let recent = state.links.filter { !queued.contains($0.id) }.sorted {
            $0.addedAt == $1.addedAt ? $0.id > $1.id : $0.addedAt > $1.addedAt
        }.prefix(max(0, recentLimit))
        sections = [("Queue", queue), ("Recent", Array(recent))].compactMap { title, links in
            links.isEmpty ? nil : MessagesPickerSection(title: title, rows: links.map {
                MessagesPickerRow(link: $0, sender: state.isMine($0) ? "You" : state.name(of: $0.addedBy))
            })
        }
    }
}

public enum MessagesPickerState: Sendable, Hashable {
    case signedOut
    case loading
    case empty(notice: String? = nil)
    case loaded(MessagesPickerContent, notice: String? = nil)
    case error(String)
}

@MainActor @Observable public final class MessagesPicker {
    public private(set) var state: MessagesPickerState = .loading
    private let token: () -> String?
    private let currentUser: () -> LinkUser?
    private let loadSnapshot: () -> InboxState?
    private let saveSnapshot: (InboxState) -> Void
    private let clearSnapshot: () -> Void
    private let clearSession: () -> Void
    private let fetch: (String) async throws -> InboxState
    private var generation = 0

    public init(token: @escaping () -> String? = { SessionStore.token },
                currentUser: @escaping () -> LinkUser? = { SessionStore.currentUser },
                loadSnapshot: @escaping () -> InboxState? = { InboxSnapshot.load() },
                saveSnapshot: @escaping (InboxState) -> Void = { InboxSnapshot.save($0) },
                clearSnapshot: @escaping () -> Void = { InboxSnapshot.clear() },
                clearSession: @escaping () -> Void = { SessionStore.clear() },
                fetch: @escaping (String) async throws -> InboxState = { try await APIClient(token: $0).state() }) {
        self.token = token
        self.currentUser = currentUser
        self.loadSnapshot = loadSnapshot
        self.saveSnapshot = saveSnapshot
        self.clearSnapshot = clearSnapshot
        self.clearSession = clearSession
        self.fetch = fetch
    }

    public func refresh() async {
        generation += 1
        let request = generation
        guard let token = token() else { state = .signedOut; return }
        let userID = currentUser()?.id
        let cached = loadSnapshot().flatMap { $0.me == userID ? $0 : nil }
        state = cached.map { display($0, notice: "Refreshing…") } ?? .loading
        do {
            let inbox = try await fetch(token)
            guard request == generation else { return }
            guard self.token() == token, currentUser()?.id == userID else { state = .signedOut; return }
            saveSnapshot(inbox)
            state = display(inbox)
        } catch {
            guard request == generation else { return }
            guard self.token() == token, currentUser()?.id == userID else { state = .signedOut; return }
            if error as? APIError == .signedOut {
                clearSession()
                clearSnapshot()
                state = .signedOut
            } else {
                let notice = "Couldn't refresh Links. \(error.localizedDescription)"
                state = cached.map { display($0, notice: notice) } ?? .error(notice)
            }
        }
    }

    private func display(_ inbox: InboxState, notice: String? = nil) -> MessagesPickerState {
        let content = MessagesPickerContent(state: inbox)
        return content.isEmpty ? .empty(notice: notice) : .loaded(content, notice: notice)
    }
}
