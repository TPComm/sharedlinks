import Foundation
import Synchronization
@testable import LinksKit

/// A request as the stub server received it.
struct Recorded: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The JSON body re-serialized with sorted keys, so tests can compare it to a literal.
    var canonicalJSON: String? {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What the stub server answers with.
enum Reply: Sendable {
    case http(status: Int, body: Data, contentType: String)
    /// The transport fails, as when the phone is offline or the request is cancelled.
    case fail(URLError.Code)
    /// A response that isn't HTTP at all.
    case notHTTP

    static func json(_ text: String, status: Int = 200) -> Reply {
        .http(status: status, body: Data(text.utf8), contentType: "application/json")
    }

    static func text(_ text: String, status: Int) -> Reply {
        .http(status: status, body: Data(text.utf8), contentType: "text/html")
    }
}

/// An in-process stand-in for the Links server. Clients it hands out go through `StubURLProtocol`,
/// so nothing touches the network. Each instance has its own made-up host, which keeps tests that
/// run in parallel from seeing each other's requests.
final class StubServer: Sendable {
    let baseURL: URL
    private let respond: @Sendable (Recorded) -> Reply
    private let log = Mutex<[Recorded]>([])

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    init(path: String = "", _ respond: @escaping @Sendable (Recorded) -> Reply) {
        let host = "\(UUID().uuidString.lowercased()).links.test"
        baseURL = URL(string: "https://\(host)\(path)")!
        self.respond = respond
        StubURLProtocol.servers.withLock { $0[host] = self }
    }

    /// Answers every request with the same reply.
    convenience init(path: String = "", always reply: Reply) {
        self.init(path: path) { _ in reply }
    }

    func client(token: String? = "tok_123") -> APIClient {
        APIClient(baseURL: baseURL, token: token, session: Self.session)
    }

    var requests: [Recorded] { log.withLock { $0 } }

    fileprivate func handle(_ request: Recorded) -> Reply {
        log.withLock { $0.append(request) }
        return respond(request)
    }
}

final class StubURLProtocol: URLProtocol {
    static let servers = Mutex<[String: StubServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let recorded = Recorded(method: request.httpMethod ?? "GET", url: url,
                                headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        switch server.handle(recorded) {
        case .http(let status, let body, let contentType):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .notHTTP:
            let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// URLSession hands protocols the body as a stream rather than `httpBody`.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
