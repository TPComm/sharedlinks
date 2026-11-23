import Foundation
import Testing
@testable import LinksKit

@Suite("Feature tours")
struct FeatureToursTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "links.tests.featureTours.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func aFreshInstallHasSeenNothing() {
        withDefaults { defaults in
            #expect(!FeatureTours(defaults: defaults).hasSeen("profilePhoto"))
            #expect(!FeatureTours(defaults: defaults).hasSeen("rollup"))
        }
    }

    @Test func seenIDsPersistIndependently() {
        withDefaults { defaults in
            let tours = FeatureTours(defaults: defaults)
            tours.markSeen("profilePhoto")
            tours.markSeen("profilePhoto")
            #expect(FeatureTours(defaults: defaults).hasSeen("profilePhoto"))
            #expect(!tours.hasSeen("rollup"))
            #expect(defaults.stringArray(forKey: FeatureTours.seenKey) == ["profilePhoto"])
            tours.markSeen("futureFeature")
            #expect(tours.hasSeen("futureFeature"))
        }
    }

    @Test func resetLeavesOnboardingAlone() {
        withDefaults { defaults in
            let tours = FeatureTours(defaults: defaults)
            Onboarding(defaults: defaults).completeTour()
            tours.markSeen("profilePhoto")
            tours.markSeen("rollup")
            tours.reset()
            tours.reset()
            #expect(!tours.hasSeen("profilePhoto"))
            #expect(!tours.hasSeen("rollup"))
            #expect(Onboarding(defaults: defaults).hasCompletedTour)
        }
    }

    @Test func invalidStoredValueStartsEmpty() {
        withDefaults { defaults in
            defaults.set(42, forKey: FeatureTours.seenKey)
            let tours = FeatureTours(defaults: defaults)
            #expect(!tours.hasSeen("profilePhoto"))
            tours.markSeen("profilePhoto")
            #expect(tours.hasSeen("profilePhoto"))
        }
    }
}
