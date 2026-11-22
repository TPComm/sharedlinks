import XCTest

@MainActor
final class FeatureTourUITests: XCTestCase {
    private var server: LinksServer!
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        server = try LinksServer.fromEnvironment()
    }

    func testNewFeaturesShowOnceAndReplayFromTheProfile() {
        launch(reset: true)
        XCTAssert(waitForTitle("Make Links Yours"))
        XCTAssert(app.buttons["featureTour.action.profilePhoto"].exists)
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Send Today's Links Together"))
        XCTAssert(app.buttons["featureTour.action.rollup"].exists)
        app.buttons["featureTour.done"].tap()
        allowNotificationsIfAsked()
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20))

        app.terminate()
        launch(reset: false)
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Make Links Yours"].waitForExistence(timeout: 3))
        app.buttons["account"].tap()
        let replay = app.buttons["profile.whatsNew"]
        for _ in 0..<6 where !(replay.exists && replay.isHittable) { app.swipeUp() }
        XCTAssert(replay.isHittable)
        replay.tap()
        XCTAssert(waitForTitle("Make Links Yours"))
        app.buttons["featureTour.skip"].tap()
        XCTAssert(app.staticTexts["Make Links Yours"].waitForNonExistence(timeout: 20))
    }

    func testSkippingMarksAllFeaturesSeen() {
        launch(reset: true)
        XCTAssert(waitForTitle("Make Links Yours"))
        app.buttons["featureTour.skip"].tap()
        allowNotificationsIfAsked()
        XCTAssert(app.staticTexts["Make Links Yours"].waitForNonExistence(timeout: 20))
        app.terminate()
        launch(reset: false)
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Make Links Yours"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Send Today's Links Together"].exists)
    }

    private func launch(reset: Bool) {
        app.launchEnvironment = [
            "LINKS_SERVER_URL": server.url.absoluteString,
            "LINKS_DEV_TOKEN": server.me,
            "LINKS_COMPLETE_ONBOARDING": "1",
        ]
        if reset { app.launchEnvironment["LINKS_RESET_FEATURE_TOURS"] = "1" }
        app.launch()
    }

    private func waitForTitle(_ title: String) -> Bool {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"),
                                              object: app.staticTexts[title])
        return XCTWaiter.wait(for: [shown], timeout: 30) == .completed
    }

    private func allowNotificationsIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }
}
