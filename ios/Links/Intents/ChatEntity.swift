import AppIntents
import LinksKit

/// A chat to pick in Shortcuts and widget settings. The app, its widgets and Shortcuts read
/// chats from the shared inbox cache, refreshed from the server when they can.
struct ChatEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let defaultQuery = ChatQuery()

    let id: Int
    let title: String
    let people: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(people)")
    }

    init(_ group: LinkGroup, in state: InboxState) {
        id = group.id
        title = state.title(of: group)
        let others = state.otherMembers(of: group).map(\.name)
        people = others.isEmpty ? "Just you" : LinkFormat.names(others)
    }
}

struct ChatQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [ChatEntity] {
        let state = await Self.state()
        return identifiers.compactMap { id in state.group(id).map { ChatEntity($0, in: state) } }
    }

    func suggestedEntities() async throws -> [ChatEntity] {
        let state = await Self.state()
        return state.groups.map { ChatEntity($0, in: state) }
    }

    /// The server's chats, or the cached ones offline.
    static func state() async -> InboxState {
        if SessionStore.isSignedIn, let fresh = try? await APIClient().state() {
            InboxSnapshot.save(fresh)
            return fresh
        }
        return InboxSnapshot.load() ?? .empty
    }
}
