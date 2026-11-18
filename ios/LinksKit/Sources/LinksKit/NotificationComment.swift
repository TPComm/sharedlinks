import Foundation

public enum NotificationComment {
    public static func send(_ body: String, on linkID: Int, client: APIClient,
                            isolation: isolated (any Actor)? = #isolation,
                            reloadWidgets: () -> Void) async throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try await client.addComment(linkID, body: body)
        if let fresh = try? await client.state() { InboxSnapshot.save(fresh) }
        reloadWidgets()
    }
}
