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

    public func exchange(code: String, verifier: String) async throws -> SignInResult {
        try await send("POST", "api/auth/token", json: ["code": code, "code_verifier": verifier])
    }

    public func signOut() async {
        let _: [String: Bool]? = try? await send("POST", "api/auth/logout")
    }

    // MARK: Account

    public func me() async throws -> MeResponse { try await send("GET", "api/me") }

    public func rename(to name: String) async throws -> MeResponse {
        try await send("PATCH", "api/me", json: ["name": name])
    }

    public func claim(_ legacyID: String) async throws -> MeResponse {
        try await send("POST", "api/me/claim", json: ["id": legacyID])
    }

    /// Deletes the account; the links it sent stay, from `LinkUser.deletedID`. Every session ends.
    public func deleteAccount() async throws {
        let _: [String: Bool] = try await send("DELETE", "api/me")
    }

    // MARK: Links

    public func state() async throws -> InboxState { try await send("GET", "api/state") }

    /// `text` can be a whole message; the server pulls the link out and cleans it up.
    public func add(_ text: String, note: String = "") async throws -> AddResult {
        try await send("POST", "api/links", json: ["url": text, "note": note])
    }

    public func setSeen(_ linkID: Int, _ seen: Bool) async throws -> SharedLink {
        let r: LinkEnvelope = try await send("POST", "api/links/\(linkID)/seen", json: ["seen": seen])
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

    public func thumbnail(_ link: SharedLink) async throws -> Data {
        guard let path = link.thumb else { throw APIError.server("No thumbnail.") }
        let parts = URLComponents(string: path)
        var req = request("GET", String((parts?.path ?? path).drop(while: { $0 == "/" })))
        if let query = parts?.queryItems { req.url?.append(queryItems: query) }
        let (data, response) = try await perform(req)
        try check(response, data)
        return data
    }

    // MARK: Plumbing

    struct LinkEnvelope: Decodable { var link: SharedLink }
    struct ErrorBody: Decodable { var error: String }

    func request(_ method: String, _ path: String, json: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
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

    func send<T: Decodable>(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> T {
        let (data, response) = try await perform(request(method, path, json: json))
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
