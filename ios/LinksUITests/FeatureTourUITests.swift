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
            in: app,
            requirePrompt: ProcessInfo.processInfo.environment["LINKS_EXPECT_NOTIFICATION_PROMPT"] == "1"
        ) { capture("Notification prompt before feature tour") }
        XCTAssert(waitForTitle("Make Links Yours"))
        XCTAssert(app.buttons["featureTour.action.profilePhoto"].exists)
        let progress = app.descendants(matching: .any)["featureTour.progress"]
        XCTAssertEqual(progress.label, "Page 1 of 6")
        capture("Profile photo action")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Send Today's Links Together"))
        XCTAssert(app.buttons["featureTour.action.rollup"].exists)
        XCTAssertEqual(progress.label, "Page 2 of 6")
        capture("Roll-up action")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Links Wrapped"))
        XCTAssertEqual(progress.label, "Page 3 of 6")
        capture("Wrapped page")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("See Who Shared It"))
        XCTAssertFalse(app.buttons["featureTour.action.sharedWithYou"].exists)
        XCTAssertEqual(progress.label, "Page 4 of 6")
        capture("Shared with You")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Nudge Friends Who Haven't Watched"))
        XCTAssertEqual(progress.label, "Page 5 of 6")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Swipe Through Your Queue"))
        XCTAssertFalse(app.buttons["featureTour.action.swipeQueue"].exists)
        XCTAssertEqual(progress.label, "Page 6 of 6")
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
        waitForNotificationsBeforeFeatureTour(in: app) { capture("Notification prompt before feature tour") }
        XCTAssert(waitForTitle("Make Links Yours"))
        app.buttons["featureTour.skip"].tap()
        XCTAssert(app.staticTexts["Make Links Yours"].waitForNonExistence(timeout: 20))
        app.terminate()
        launch(reset: false)
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Make Links Yours"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Send Today's Links Together"].exists)
        XCTAssertFalse(app.staticTexts["See Who Shared It"].exists)
        XCTAssertFalse(app.staticTexts["Nudge Friends Who Haven't Watched"].exists)
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

    private func capture(_ name: String) {
        guard ProcessInfo.processInfo.environment["LINKS_CAPTURE_FEATURE_TOUR_SCREENSHOTS"] == "1" else { return }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCTestCase {
    @MainActor
    func waitForNotificationsBeforeFeatureTour(in app: XCUIApplication, requirePrompt: Bool = false,
                                              onPrompt: () -> Void = {}) {
        let springBoard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springBoard.alerts.buttons["Allow"]
        let featureTour = app.buttons["featureTour.skip"]
        let deadline = ContinuousClock.now + .seconds(90)
        var answeredPrompt = false
        var failure = "neither the notification prompt nor the feature tour appeared"
        repeat {
            if allow.exists, !answeredPrompt {
                if featureTour.exists {
                    failure = "feature tour opened behind the notification prompt"
                    break
                }
                onPrompt()
                allow.tap()
                answeredPrompt = true
                failure = "feature tour did not appear after answering the notification prompt"
            } else if featureTour.exists, featureTour.isHittable, !allow.exists {
                if !requirePrompt || answeredPrompt { return }
                failure = "feature tour opened before the notification prompt"
                break
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while ContinuousClock.now < deadline

        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = failure
        screen.lifetime = .keepAlways
        add(screen)
        for (name, target) in [("App", app), ("SpringBoard", springBoard)] {
            let tree = XCTAttachment(string: target.debugDescription)
            tree.name = "\(name) accessibility hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTFail(failure)
    }
}
