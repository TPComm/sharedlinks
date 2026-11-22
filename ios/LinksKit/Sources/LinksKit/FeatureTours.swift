import Foundation

/// Feature announcements seen on this device, shared with the app's extensions.
public struct FeatureTours: Sendable {
    nonisolated(unsafe) let defaults: UserDefaults
    static let seenKey = "links.featureTours.seen"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static var shared: FeatureTours { FeatureTours(defaults: LinksConfig.sharedDefaults) }

    public func hasSeen(_ id: String) -> Bool {
        (defaults.stringArray(forKey: Self.seenKey) ?? []).contains(id)
    }

    public func markSeen(_ id: String) {
        var seen = defaults.stringArray(forKey: Self.seenKey) ?? []
        guard !seen.contains(id) else { return }
        seen.append(id)
        defaults.set(seen, forKey: Self.seenKey)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.seenKey)
    }
}
