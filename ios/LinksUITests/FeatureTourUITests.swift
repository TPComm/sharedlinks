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
        waitForNotificationsBeforeFeatureTour(
            requirePrompt: ProcessInfo.processInfo.environment["LINKS_EXPECT_NOTIFICATION_PROMPT"] == "1"
        )
        XCTAssert(waitForTitle("Make Links Yours"))
        XCTAssert(app.buttons["featureTour.action.profilePhoto"].exists)
        let progress = app.descendants(matching: .any)["featureTour.progress"]
        XCTAssertEqual(progress.label, "Page 1 of 3")
        capture("Profile photo action")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Send Today's Links Together"))
        XCTAssert(app.buttons["featureTour.action.rollup"].exists)
        XCTAssertEqual(progress.label, "Page 2 of 3")
        capture("Roll-up action")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Swipe Through Your Queue"))
        XCTAssertFalse(app.buttons["featureTour.action.swipeQueue"].exists)
        XCTAssertEqual(progress.label, "Page 3 of 3")
        app.buttons["featureTour.done"].tap()
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
        waitForNotificationsBeforeFeatureTour()
        XCTAssert(waitForTitle("Make Links Yours"))
        app.buttons["featureTour.skip"].tap()
        XCTAssert(app.staticTexts["Make Links Yours"].waitForNonExistence(timeout: 20))
        app.terminate()
        launch(reset: false)
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Make Links Yours"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Send Today's Links Together"].exists)
        XCTAssertFalse(app.staticTexts["Swipe Through Your Queue"].exists)
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

    private func waitForNotificationsBeforeFeatureTour(requirePrompt: Bool = false) {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        let featureTour = app.buttons["featureTour.skip"]
        let deadline = ContinuousClock.now + .seconds(60)
        repeat {
            if allow.exists {
                XCTAssertFalse(featureTour.exists, "feature tour opened behind the notification prompt")
                capture("Notification prompt before feature tour")
                allow.tap()
                return
            }
            if featureTour.waitForExistence(timeout: 1) {
                XCTAssertFalse(requirePrompt, "feature tour opened before the notification prompt")
                return
            }
        } while ContinuousClock.now < deadline
        XCTFail("neither the notification prompt nor the feature tour appeared")
    }

    private func capture(_ name: String) {
        guard ProcessInfo.processInfo.environment["LINKS_CAPTURE_FEATURE_TOUR_SCREENSHOTS"] == "1" else { return }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
