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

    /// The server's privacy policy page (App Store guideline 5.1.1(i)).
    public static var privacyPolicyURL: URL {
        serverURL.appending(path: "privacy")
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
    /// Shows that link's page in the app, on the tab whose list has it. It doesn't jump on to
    /// TikTok: from the page that's one tap, and coming back lands on the page to react and mark
    /// it watched. (A widget's ✓ button marks it watched without opening anything.)
    case open(linkID: Int)
    case add
    case inbox
    /// An invite to this Links (#5): the token goes with the sign-in. Either
    /// `sharedlinks://invite/<token>` (the invite page's Open in Links) or the server's own
    /// `https://<server>/invite/<token>`, the link people send (a universal link once the app
    /// claims the domain).
    case invite(token: String)

    /// `webHost` is the server's: an https link only counts when it's the server's invite page.
    public init?(url: URL, webHost: String? = LinksConfig.serverURL.host()) {
        if url.scheme?.lowercased() == "https" {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard let webHost, url.host()?.lowercased() == webHost.lowercased(), parts.count >= 2,
                  parts[parts.count - 2] == "invite", Self.isInviteToken(parts[parts.count - 1]) else { return nil }
            self = .invite(token: parts[parts.count - 1])
            return
        }
        guard url.scheme == LinksConfig.urlScheme else { return nil }
        let parts = [url.host()].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
        switch parts.first {
        case "invite":
            guard parts.count > 1, Self.isInviteToken(parts[1]) else { return nil }
            self = .invite(token: parts[1])
        case "open": self = parts.count > 1 ? Int(parts[1]).map { .open(linkID: $0) } ?? .inbox : .inbox
        case "add": self = .add
        case "inbox": self = .inbox
        default: return nil
        }
    }

    public var url: URL {
        switch self {
        case .open(let id): URL(string: "\(LinksConfig.urlScheme)://open/\(id)")!
        case .add: URL(string: "\(LinksConfig.urlScheme)://add")!
        case .inbox: URL(string: "\(LinksConfig.urlScheme)://inbox")!
        case .invite(let token): URL(string: "\(LinksConfig.urlScheme)://invite/\(token)")!
        }
    }

    /// The server's invite tokens: 32 random bytes, base64url (server/src/accounts.ts).
    static func isInviteToken(_ s: String) -> Bool {
        s.count == 43 && s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }
}
