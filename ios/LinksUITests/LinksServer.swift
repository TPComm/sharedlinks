import Foundation
import XCTest

/// The server the app under test talks to, called directly to set up and check state.
/// `ios/scripts/ui-tests.sh` starts it with an empty database and passes its URL and session
/// tokens to the test runner (the Simulator shares the Mac's localhost).
/// Synchronous, like XCUITest itself, so tests read top to bottom.
struct LinksServer: Sendable {
    let url: URL
    /// Sessions for two people: "Me" (the app signs in as this) and "Friend".
    let me: String
    let friend: String
    /// Another session of "Me", for the test that signs out (which ends the session).
    let spare: String
    /// A third person, for the test that deletes their account.
    let deletable: String

    static func fromEnvironment() throws -> LinksServer {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["LINKS_SERVER_URL"], let url = URL(string: raw),
              let me = env["LINKS_DEV_TOKEN"], let friend = env["LINKS_FRIEND_TOKEN"],
              let spare = env["LINKS_SPARE_TOKEN"], let deletable = env["LINKS_DELETABLE_TOKEN"],
              ![me, friend, spare, deletable].contains("") else {
            throw XCTSkip("Run ios/scripts/ui-tests.sh, which starts a server for these tests.")
        }
        return LinksServer(url: url, me: me, friend: friend, spare: spare, deletable: deletable)
    }

    struct Link: Decodable, Sendable {
        let id: Int
        let url: String
        let note: String
        let addedBy: String
        let seen: [String: Double]
        let reactions: [String: String]

        enum CodingKeys: String, CodingKey {
            case id, url, note, seen, reactions
            case addedBy = "added_by"
        }
    }

    struct State: Decodable, Sendable {
        /// The id of whoever's token asked.
        let me: String
        let links: [Link]

        func link(_ id: Int) -> Link? { links.first { $0.id == id } }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: API

    func add(_ text: String, note: String = "", as token: String) throws -> Link {
        struct Added: Decodable { let link: Link }
        let data = try send("POST", "api/links", json: ["url": text, "note": note], as: token)
        return try JSONDecoder().decode(Added.self, from: data).link
    }

    func setSeen(_ id: Int, _ seen: Bool, as token: String) throws {
        _ = try send("POST", "api/links/\(id)/seen", json: ["seen": seen], as: token)
    }

    func delete(_ id: Int, as token: String) throws {
        _ = try send("DELETE", "api/links/\(id)", as: token)
    }

    func state(as token: String) throws -> State {
        try JSONDecoder().decode(State.self, from: try send("GET", "api/state", as: token))
    }

    /// Just the status code, for checking that a request is refused.
    func status(_ method: String, _ path: String, as token: String) throws -> Int {
        try load(request(method, path, json: nil, as: token)).status
    }

    /// Polls until `check` returns a value: the app sends its requests in the background, so the
    /// server catches up a moment after the screen does.
    @discardableResult
    func eventually<T>(timeout: TimeInterval = 10, _ what: String, _ check: () throws -> T?) throws -> T {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            if let value = try check() { return value }
            guard Date.now < deadline else { throw Failure(description: "Timed out waiting for the server: \(what)") }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String, json: [String: Any]?, as token: String) -> URLRequest {
        var request = URLRequest(url: url.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func send(_ method: String, _ path: String, json: [String: Any]? = nil, as token: String) throws -> Data {
        let (data, status) = try load(request(method, path, json: json, as: token))
        guard (200..<300).contains(status) else {
            throw Failure(description: "\(method) /\(path): \(status) \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    private final class Response: @unchecked Sendable {
        var result: Result<(data: Data, status: Int), Error> = .failure(Failure(description: "no response"))
    }

    private func load(_ request: URLRequest) throws -> (data: Data, status: Int) {
        let response = Response()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, urlResponse, error in
            if let error {
                response.result = .failure(error)
            } else {
                response.result = .success((data ?? Data(), (urlResponse as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()
        return try response.result.get()
    }
}
