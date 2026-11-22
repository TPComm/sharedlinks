import Foundation

public enum APIError: LocalizedError, Sendable, Equatable {
    case signedOut
    case server(String)
    case offline

    public var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to Links to continue."
        case .server(let message): message
        case .offline: "Can't reach Links right now."
        }
    }
}

/// Talks to server.py. Stateless and `Sendable`, so the app, the Share Extension and the
/// widget each make their own with the shared session token.
public struct APIClient: Sendable {
    public var baseURL: URL
    public var token: String?
    var session: URLSession

    public init(baseURL: URL = LinksConfig.serverURL, token: String? = SessionStore.token,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    // MARK: Sign-in

    /// The page to open in ASWebAuthenticationSession. The server forwards to AuthKit.
    public func authorizeURL(pkce: PKCE, signUp: Bool = false) -> URL {
        var items = [URLQueryItem(name: "code_challenge", value: pkce.challenge),
                     URLQueryItem(name: "state", value: pkce.state)]
        if signUp { items.append(URLQueryItem(name: "screen_hint", value: "sign-up")) }
        return baseURL.appending(path: "auth/authorize").appending(queryItems: items)
    }

    /// `invite` is the token from an invite link opened before signing in; the server uses it up, and
    /// the result's `groupID` is the chat it took them to.
    public func exchange(code: String, verifier: String, invite: String? = nil) async throws -> SignInResult {
        var body: [String: Any] = ["code": code, "code_verifier": verifier]
        if let invite { body["invite"] = invite }
        return try await send("POST", "api/auth/token", json: body)
    }

    public func signOut() async {
        let _: [String: Bool]? = try? await send("POST", "api/auth/logout")
    }

    /// Hands the server this phone's APNs token for the session (signing out removes it).
    /// Returns whether the server sends push notifications at all.
    public func registerDevice(token: String, env: String) async throws -> Bool {
        struct Registered: Decodable { var push: Bool? }
        let r: Registered = try await send("POST", "api/devices", json: ["token": token, "env": env])
        return r.push ?? false
    }

    // MARK: Account

    public func me() async throws -> MeResponse { try await send("GET", "api/me") }

    public func rename(to name: String) async throws -> MeResponse {
        try await send("PATCH", "api/me", json: ["name": name])
    }

    /// Changes only the settings given; nil leaves one as it is.
    public func setNotifications(watched: Bool? = nil, reactions: Bool? = nil) async throws -> MeResponse {
        var settings: [String: Bool] = [:]
        if let watched { settings["watched"] = watched }
        if let reactions { settings["reactions"] = reactions }
        return try await send("PATCH", "api/me", json: ["notifications": settings])
    }

    public func claim(_ legacyID: String) async throws -> MeResponse {
        try await send("POST", "api/me/claim", json: ["id": legacyID])
    }

    /// Makes a `ProfilePhoto.jpeg` my avatar (#97), in place of the WorkOS picture.
    public func setPhoto(_ jpeg: Data) async throws -> MeResponse {
        var upload = request("PUT", "api/me/photo")
        upload.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        upload.httpBody = jpeg
        let (data, response) = try await perform(upload)
        try check(response, data)
        return try Self.decoder.decode(MeResponse.self, from: data)
    }

    /// Back to initials, hiding the WorkOS picture too.
    public func removePhoto() async throws -> MeResponse { try await send("DELETE", "api/me/photo") }

    /// Deletes the account; the links it sent stay, from `LinkUser.deletedID`. Every session ends.
    public func deleteAccount() async throws {
        let _: [String: Bool] = try await send("DELETE", "api/me")
    }

    // MARK: Links

    public func state() async throws -> InboxState { try await send("GET", "api/state") }

    public func wrapped(start: Date, end: Date, groupID: Int? = nil) async throws -> Wrapped {
        var req = request("GET", "api/wrapped")
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "start", value: String(Int(start.timeIntervalSince1970))),
                                 URLQueryItem(name: "end", value: String(Int(end.timeIntervalSince1970)))]
        if let groupID { components.queryItems?.append(URLQueryItem(name: "group_id", value: String(groupID))) }
        req.url = components.url
        let (data, response) = try await perform(req)
        try check(response, data)
        return try Self.decoder.decode(Wrapped.self, from: data)
    }

    /// `text` can be a whole message; the server pulls the link out and cleans it up.
    /// `groupID` is the chat it goes to; without one, the server picks the default chat.
    public func add(_ text: String, note: String = "", groupID: Int? = nil) async throws -> AddResult {
        var body: [String: Any] = ["url": text, "note": note]
        if let groupID { body["group_id"] = groupID }
        return try await send("POST", "api/links", json: body)
    }

    // MARK: Chats

    /// Starts a chat with me and `members` (user ids) in it. An empty name lets the app name it.
    public func createGroup(name: String = "", members: [String]) async throws -> LinkGroup {
        let r: GroupEnvelope = try await send("POST", "api/groups", json: ["name": name, "members": members])
        return r.group
    }

    public func renameGroup(_ id: Int, to name: String) async throws -> LinkGroup {
        let r: GroupEnvelope = try await send("PATCH", "api/groups/\(id)", json: ["name": name])
        return r.group
    }

    public func setGroupMuted(_ id: Int, muted: Bool, until: Date? = nil) async throws -> LinkGroup {
        var body: [String: Any] = ["muted": muted]
        if muted, let until { body["muted_until"] = until.timeIntervalSince1970 }
        let r: GroupEnvelope = try await send("PATCH", "api/groups/\(id)", json: body)
        return r.group
    }

    /// Adds people already in Links. Nobody can remove anyone else; they can only leave.
    public func addMembers(_ members: [String], to id: Int) async throws -> LinkGroup {
        let r: GroupEnvelope = try await send("POST", "api/groups/\(id)/members", json: ["members": members])
        return r.group
    }

    /// Leaves a chat. The links I sent stay in it for everyone else.
    public func leaveGroup(_ id: Int) async throws {
        let _: [String: Bool] = try await send("DELETE", "api/groups/\(id)")
    }

    public func setSeen(_ linkID: Int, _ seen: Bool) async throws -> SharedLink {
        let r: LinkEnvelope = try await send("POST", "api/links/\(linkID)/seen", json: ["seen": seen])
        return r.link
    }

    public func nudge(_ linkID: Int, people: [String]? = nil) async throws -> SharedLink {
        let r: LinkEnvelope = try await send("POST", "api/links/\(linkID)/nudge",
                                             json: people.map { ["people": $0] } ?? [:])
        return r.link
    }

    public func setFavorite(_ linkID: Int, _ starred: Bool) async throws -> SharedLink {
        let r: LinkEnvelope = try await send(starred ? "PUT" : "DELETE", "api/links/\(linkID)/favorite")
        return r.link
    }

    /// `nil` removes my reaction.
    public func react(_ linkID: Int, _ emoji: String?) async throws -> SharedLink {
        let r: LinkEnvelope = try await send("POST", "api/links/\(linkID)/react",
                                             json: ["emoji": emoji ?? NSNull()])
        return r.link
    }

    /// Asks the server to fetch the link's preview again (after it failed).
    public func refreshPreview(_ linkID: Int) async throws -> SharedLink {
        let r: LinkEnvelope = try await send("POST", "api/links/\(linkID)/refresh", json: [:])
        return r.link
    }

    public func setNote(_ linkID: Int, _ note: String) async throws -> SharedLink {
        let r: LinkEnvelope = try await send("PATCH", "api/links/\(linkID)", json: ["note": note])
        return r.link
    }

    public func delete(_ linkID: Int) async throws {
        let _: [String: Bool] = try await send("DELETE", "api/links/\(linkID)")
    }

    // MARK: Comments

    public func comments(_ linkID: Int) async throws -> [LinkComment] {
        struct Envelope: Decodable { let comments: [LinkComment] }
        let result: Envelope = try await send("GET", "api/links/\(linkID)/comments")
        return result.comments
    }

    public func addComment(_ linkID: Int, body: String) async throws -> LinkComment {
        struct Envelope: Decodable { let comment: LinkComment }
        let result: Envelope = try await send("POST", "api/links/\(linkID)/comments", json: ["body": body])
        return result.comment
    }

    public func editComment(_ id: Int, body: String) async throws -> LinkComment {
        struct Envelope: Decodable { let comment: LinkComment }
        let result: Envelope = try await send("PATCH", "api/comments/\(id)", json: ["body": body])
        return result.comment
    }

    public func deleteComment(_ id: Int) async throws {
        let _: [String: Bool] = try await send("DELETE", "api/comments/\(id)")
    }

    // MARK: Reports and blocks

    /// Reports a link to whoever runs the server; it's hidden for me from then on.
    public func report(link linkID: Int, reason: ReportReason) async throws {
        let _: [String: Bool] = try await send("POST", "api/reports", json: ["link_id": linkID, "reason": reason.rawValue])
    }

    /// Hides a comment for me and sends its snapshot to moderation.
    public func report(comment commentID: Int, reason: ReportReason) async throws {
        let _: [String: Bool] = try await send("POST", "api/reports", json: ["comment_id": commentID, "reason": reason.rawValue])
    }

    /// Reports a person (their name or photo).
    public func report(person userID: String, reason: ReportReason) async throws {
        let _: [String: Bool] = try await send("POST", "api/reports", json: ["user_id": userID, "reason": reason.rawValue])
    }

    /// Returns everyone I've blocked now.
    public func block(_ userID: String) async throws -> [String] {
        let r: BlockedEnvelope = try await send("POST", "api/blocks", json: ["user_id": userID])
        return r.blocked
    }

    public func unblock(_ userID: String) async throws -> [String] {
        let r: BlockedEnvelope = try await send("DELETE", "api/blocks", component: userID)
        return r.blocked
    }

    // MARK: Invites

    public func chatInviteLink(groupID: Int) async throws -> ChatInviteLink? {
        let r: ChatLinkEnvelope = try await send("GET", "api/groups/\(groupID)/link")
        return r.link
    }

    public func resetChatInviteLink(groupID: Int) async throws -> ChatInviteLink {
        let r: ChatLinkEnvelope = try await send("POST", "api/groups/\(groupID)/link")
        guard let link = r.link else { throw APIError.server("The invite link wasn't created. Try again.") }
        return link
    }

    public func turnOffChatInviteLink(groupID: Int) async throws {
        let _: ChatLinkEnvelope = try await send("DELETE", "api/groups/\(groupID)/link")
    }

    private struct ChatLinkEnvelope: Decodable { var link: ChatInviteLink? }

    /// Mine that nobody has used yet, newest first.
    public func invites() async throws -> [Invite] {
        let r: InvitesEnvelope = try await send("GET", "api/invites")
        return r.invites
    }

    /// A new invite, with its link. `email` lets that person in even if the link gets lost.
    /// `groupID` is the chat they join; without it they get a chat with just me.
    public func createInvite(email: String? = nil, groupID: Int? = nil) async throws -> Invite {
        var body: [String: Any] = [:]
        if let email { body["email"] = email }
        if let groupID { body["group_id"] = groupID }
        let r: InviteEnvelope = try await send("POST", "api/invites", json: body)
        return r.invite
    }

    /// An invite link opened while signed in: joins the chat it's for and returns it, or nil when
    /// there's nothing to join (my own invite, or an admin's).
    public func acceptInvite(_ token: String) async throws -> LinkGroup? {
        struct Accepted: Decodable { var group: LinkGroup? }
        let r: Accepted = try await send("POST", "api/invites/accept", json: ["token": token])
        return r.group
    }

    /// Returns the invites still pending.
    public func revokeInvite(_ id: Int) async throws -> [Invite] {
        let r: InvitesEnvelope = try await send("DELETE", "api/invites", component: String(id))
        return r.invites
    }

    public func thumbnail(_ link: SharedLink) async throws -> Data {
        guard let path = link.thumb else { throw APIError.server("No thumbnail.") }
        return try await thumbnail(path: path).data
    }

    /// A thumbnail by its path on the server (`SharedLink.thumb`, or a new-link push's `thumb`).
    public func thumbnail(path: String) async throws -> (data: Data, type: String?) {
        let (data, response) = try await perform(request("GET", String(path.drop(while: { $0 == "/" }))))
        try check(response, data)
        return (data, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: Plumbing

    struct LinkEnvelope: Decodable { var link: SharedLink }
    struct BlockedEnvelope: Decodable { var blocked: [String] }
    struct InviteEnvelope: Decodable { var invite: Invite }
    struct InvitesEnvelope: Decodable { var invites: [Invite] }
    struct ErrorBody: Decodable { var error: String }

    /// `component` is one more path segment, escaped (an id with a "/" in it stays one segment).
    func request(_ method: String, _ path: String, component: String? = nil, json: [String: Any]? = nil) -> URLRequest {
        var url = baseURL.appending(path: path)
        if let component { url = url.appending(component: component) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    func send<T: Decodable>(_ method: String, _ path: String, component: String? = nil,
                            json: [String: Any]? = nil) async throws -> T {
        let (data, response) = try await perform(request(method, path, component: component, json: json))
        try check(response, data)
        return try Self.decoder.decode(T.self, from: data)
    }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw APIError.offline
        }
    }

    func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        if http.statusCode == 401 { throw APIError.signedOut }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? Self.decoder.decode(ErrorBody.self, from: data))?.error
            throw APIError.server(message ?? "Something went wrong (\(http.statusCode)).")
        }
    }
}
