import Foundation

/// Values every target reads from its own Info.plist, which gets them from `Config.xcconfig`.
public enum LinksConfig {
    /// Where the Links API (server.py) runs.
    public static var serverURL: URL {
        #if DEBUG
        // UI tests launch the app against their own server (ios/scripts/ui-tests.sh), since the
        // dev server usually has localhost:8000. Only the app's process sees this, not extensions.
        if let raw = ProcessInfo.processInfo.environment["LINKS_SERVER_URL"], !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        #endif
        let raw = Bundle.main.object(forInfoDictionaryKey: "LinksServerURL") as? String ?? ""
        return URL(string: raw.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://localhost:8000")!
    }

    /// Where people reach whoever runs the server (App Store guideline 1.2), from LINKS_SUPPORT_URL:
    /// a mailto: or https: URL. Nil if it isn't set.
    public static var supportURL: URL? {
        parseSupportURL(Bundle.main.object(forInfoDictionaryKey: "LinksSupportURL") as? String)
    }

    static func parseSupportURL(_ raw: String?) -> URL? {
        let raw = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let url = URL(string: raw), ["mailto", "https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// The support address as people read it: "help@example.com", or "example.com/support".
    public static func supportAddress(_ url: URL) -> String {
        if url.scheme?.lowercased() == "mailto" {
            return url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
        }
        let host = url.host()?.replacingOccurrences(of: "www.", with: "", options: .anchored) ?? ""
        let path = url.path()
        return path == "/" || path.isEmpty ? host : host + path
    }

    /// The App Group the app and its extensions share (keychain item, inbox cache, thumbnails).
    public static var appGroup: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "LinksAppGroup") as? String
        return value?.isEmpty == false ? value : nil
    }

    /// The server's host, whose https://HOST/l/, /invite/ and /g/ links open the app (universal links).
    public static var associatedDomain: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "LinksAssociatedDomain") as? String)?
            .trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    /// Must match the server's APP_SCHEME. Also used for widget deep links.
    public static let urlScheme = "sharedlinks"

    public static var sharedDefaults: UserDefaults {
        appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public static var sharedContainer: URL {
        if let appGroup,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}

/// Deep links the widgets use to open the app.
public enum DeepLink: Equatable, Sendable {
    case open(linkID: Int)
    case add
    case inbox
    /// `https://HOST/l/<token>`: a link's page.
    case link(token: String)
    /// `https://HOST/invite/<token>`.
    case invite(token: String)
    /// `https://HOST/g/<id>`: a chat.
    case group(id: String)

    /// Parses `sharedlinks://…` and the universal links on `associatedDomain`
    /// (any other https URL, including the server's /api and /auth ones, is nil).
    public init?(url: URL, associatedDomain: String? = LinksConfig.associatedDomain) {
        let parts: [String]
        switch url.scheme?.lowercased() {
        case LinksConfig.urlScheme:
            parts = [url.host()].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
        case "https":
            guard let associatedDomain, !associatedDomain.isEmpty, url.port == nil,
                  url.host()?.lowercased() == associatedDomain.lowercased() else { return nil }
            parts = url.pathComponents.filter { $0 != "/" }
            guard ["l", "invite", "g"].contains(parts.first) else { return nil }
        default:
            return nil
        }
        switch parts.first {
        case "open": self = parts.count > 1 ? Int(parts[1]).map { .open(linkID: $0) } ?? .inbox : .inbox
        case "add": self = .add
        case "inbox": self = .inbox
        case "l", "invite", "g":
            guard parts.count == 2, Self.isToken(parts[1]) else { return nil }
            switch parts[0] {
            case "l": self = .link(token: parts[1])
            case "invite": self = .invite(token: parts[1])
            default: self = .group(id: parts[1])
            }
        default: return nil
        }
    }

    public var url: URL {
        switch self {
        case .open(let id): URL(string: "\(LinksConfig.urlScheme)://open/\(id)")!
        case .add: URL(string: "\(LinksConfig.urlScheme)://add")!
        case .inbox: URL(string: "\(LinksConfig.urlScheme)://inbox")!
        case .link(let token): URL(string: "\(LinksConfig.urlScheme)://l/\(token)")!
        case .invite(let token): URL(string: "\(LinksConfig.urlScheme)://invite/\(token)")!
        case .group(let id): URL(string: "\(LinksConfig.urlScheme)://g/\(id)")!
        }
    }

    /// The server's rule for /l/, /invite/ and /g/ parameters.
    static func isToken(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
