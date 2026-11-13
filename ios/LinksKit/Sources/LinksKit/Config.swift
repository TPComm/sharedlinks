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
    case open(linkID: Int)
    case add
    case inbox

    public init?(url: URL) {
        guard url.scheme == LinksConfig.urlScheme else { return nil }
        let parts = [url.host()].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
        switch parts.first {
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
        }
    }
}
