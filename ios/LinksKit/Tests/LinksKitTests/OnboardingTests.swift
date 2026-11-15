import Foundation
import Testing
@testable import LinksKit

@Suite("Onboarding")
struct OnboardingTests {
    /// A defaults suite of its own per test, removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "links.tests.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func aFreshInstallHasSeenNothing() {
        withDefaults { defaults in
            let onboarding = Onboarding(defaults: defaults)
            #expect(!onboarding.hasCompletedTour)
            #expect(!onboarding.hasOpenedShareExtension)
        }
    }

    @Test func completingTheTourSticks() {
        withDefaults { defaults in
            Onboarding(defaults: defaults).completeTour()
            // Another process (or a later launch) reads the same flag.
            #expect(Onboarding(defaults: defaults).hasCompletedTour)
            #expect(!Onboarding(defaults: defaults).hasOpenedShareExtension)
        }
    }

    @Test func theShareExtensionKeepsTheFirstOpening() throws {
        try withDefaults { defaults in
            let onboarding = Onboarding(defaults: defaults)
            let first = Date(timeIntervalSince1970: 1_000)
            onboarding.recordShareExtensionOpened(at: first)
            onboarding.recordShareExtensionOpened(at: Date(timeIntervalSince1970: 2_000))
            #expect(onboarding.hasOpenedShareExtension)
            let stored = try #require(defaults.object(forKey: Onboarding.shareExtensionKey) as? Date)
            #expect(stored == first)
        }
    }

    @Test func resetStartsOver() {
        withDefaults { defaults in
            let onboarding = Onboarding(defaults: defaults)
            onboarding.completeTour()
            onboarding.recordShareExtensionOpened()
            onboarding.reset()
            #expect(!onboarding.hasCompletedTour)
            #expect(!onboarding.hasOpenedShareExtension)
        }
    }

    @Test func theAppTellsTheShareExtensionToHoldThePracticeConfirmation() {
        withDefaults { defaults in
            #expect(!Onboarding(defaults: defaults).holdsPracticeConfirmation)
            Onboarding(defaults: defaults).holdsPracticeConfirmation = true
            #expect(Onboarding(defaults: defaults).holdsPracticeConfirmation)
            Onboarding(defaults: defaults).holdsPracticeConfirmation = false
            #expect(!Onboarding(defaults: defaults).holdsPracticeConfirmation)
        }
    }

    @Test(arguments: [
        "https://example.com/links-share-sheet-practice",
        "https://EXAMPLE.com/links-share-sheet-practice",
        "https://example.com/links-share-sheet-practice?utm=x",
        "http://example.com/links-share-sheet-practice",
    ])
    func recognisesThePracticeLink(_ raw: String) {
        #expect(Onboarding.isPractice(URL(string: raw)))
    }

    @Test(arguments: [
        "https://example.com/",
        "https://example.com/links-share-sheet-practice/more",
        "https://www.tiktok.com/@someone/video/123",
        "https://example.org/links-share-sheet-practice",
    ])
    func realLinksAreNotPractice(_ raw: String) {
        #expect(!Onboarding.isPractice(URL(string: raw)))
    }

    @Test func noLinkIsNotPractice() {
        #expect(!Onboarding.isPractice(nil))
    }
}
