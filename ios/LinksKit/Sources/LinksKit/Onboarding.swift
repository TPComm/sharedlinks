import Foundation

/// First-run state, kept in the App Group's defaults so the Share Extension can report in: whether
/// the welcome tour has been seen, and whether Links has ever been opened from the share sheet.
/// It's per device, not per account: a share sheet is set up on a device.
public struct Onboarding: Sendable {
    nonisolated(unsafe) let defaults: UserDefaults

    static let tourKey = "links.onboarding.tourCompleted"
    static let shareExtensionKey = "links.onboarding.shareExtensionOpened"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The App Group's copy, which the app and its extensions share.
    public static var shared: Onboarding { Onboarding(defaults: LinksConfig.sharedDefaults) }

    /// Finished or skipped the welcome tour.
    public var hasCompletedTour: Bool { defaults.object(forKey: Self.tourKey) != nil }

    public func completeTour(at date: Date = .now) {
        defaults.set(date, forKey: Self.tourKey)
    }

    /// The Share Extension has opened at least once, so Links is reachable from the share sheet.
    public var hasOpenedShareExtension: Bool { defaults.object(forKey: Self.shareExtensionKey) != nil }

    /// Called by the Share Extension each time it opens; only the first time is kept.
    public func recordShareExtensionOpened(at date: Date = .now) {
        guard !hasOpenedShareExtension else { return }
        defaults.set(date, forKey: Self.shareExtensionKey)
    }

    /// Back to a first launch (debug builds, for the tour's UI test).
    public func reset() {
        defaults.removeObject(forKey: Self.tourKey)
        defaults.removeObject(forKey: Self.shareExtensionKey)
    }

    /// What the tour's "Try It Now" shares. The Share Extension recognises it and says it's ready,
    /// rather than sending a practice link to everyone. A reserved domain, so it's harmless anywhere
    /// else it ends up (Messages, Copy).
    public static let practiceURL = URL(string: "https://example.com/links-share-sheet-practice")!

    public static func isPractice(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host()?.lowercased() == practiceURL.host() && url.path() == practiceURL.path()
    }
}
