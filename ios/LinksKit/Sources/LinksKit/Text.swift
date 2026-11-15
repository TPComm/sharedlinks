import Foundation

public enum LinkText {
    /// The first web link in some shared text ("lol look https://vm.tiktok.com/..."),
    /// found with the system's data detector, the same one Messages uses.
    public static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased()) }
    }

    /// The web link in a shared URL or text attachment. SwiftUI's ShareLink hands over URL data.
    public static func webURL(fromSharedItem item: Any?) -> URL? {
        let url: URL? = switch item {
        case let url as URL: url
        case let data as Data: url(fromURLData: data)
        case let string as String: url(fromSharedText: string)
        default: nil
        }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// public.url as data: on iOS a property list, [string, base, {}]; elsewhere the bare string.
    static func url(fromURLData data: Data) -> URL? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        let string = (plist as? [Any])?.first as? String ?? plist as? String ?? String(data: data, encoding: .utf8)
        return string.flatMap { url(fromSharedText: $0) }
    }

    static func url(fromSharedText text: String) -> URL? {
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) { return url }
        return firstURL(in: text)
    }
}

public enum LinkFormat {
    /// Compact, Messages-style times: now, 5m, 3h, Yesterday, Tue, Mar 4.
    public static func ago(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        let days = Int(seconds / 86400)
        if days < 2 { return "Yesterday" }
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Sam", "Sam and Alex", "Sam, Alex, and Jo", localized.
    public static func names(_ names: [String]) -> String {
        names.formatted(.list(type: .and))
    }
}
