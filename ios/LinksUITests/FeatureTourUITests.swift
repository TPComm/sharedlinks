import XCTest

@MainActor
final class FeatureTourUITests: XCTestCase {
    private var server: LinksServer!
    private var app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        server = try LinksServer.fromEnvironment()
    }

    override func tearDown() async throws {
        await MainActor.run { app.quit() }
        try await super.tearDown()
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
        XCTAssertEqual(progress.label, "Page 1 of 10")
        capture("Profile photo action")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Send Today's Links Together"))
        XCTAssert(app.buttons["featureTour.action.rollup"].exists)
        XCTAssertEqual(progress.label, "Page 2 of 10")
        capture("Roll-up action")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Links Wrapped"))
        XCTAssertEqual(progress.label, "Page 3 of 10")
        capture("Wrapped page")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("See Who Shared It"))
        XCTAssertFalse(app.buttons["featureTour.action.sharedWithYou"].exists)
        XCTAssertEqual(progress.label, "Page 4 of 10")
        capture("Shared with You")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Nudge Friends About Links They Haven't Seen"))
        XCTAssertEqual(progress.label, "Page 5 of 10")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Swipe Through Your Queue"))
        XCTAssertFalse(app.buttons["featureTour.action.swipeQueue"].exists)
        XCTAssertEqual(progress.label, "Page 6 of 10")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("React With Any Emoji"))
        XCTAssertEqual(progress.label, "Page 7 of 10")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Save Your Favorites"))
        XCTAssertEqual(progress.label, "Page 8 of 10")
        capture("Favorites tour")
        XCTAssert(app.buttons["featureTour.action.favorites"].exists)
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Invite Friends to a Chat"))
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Friends already on Links who tap it join the chat.")).firstMatch.exists)
        XCTAssertEqual(progress.label, "Page 9 of 10")
        app.buttons["featureTour.continue"].tap()
        XCTAssert(waitForTitle("Get a Daily Catch-Up"))
        XCTAssertEqual(progress.label, "Page 10 of 10")
        capture("Daily catch-up")
        app.buttons["featureTour.done"].tap()
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20))

        app.quit()
        launch(reset: false)
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Make Links Yours"].waitForExistence(timeout: 3))
        app.buttons["account"].tap()
        tapWhatsNew()
        waitForNotificationsBeforeFeatureTour(in: app)
        XCTAssert(waitForTitle("Make Links Yours"))
        for title in ["Send Today's Links Together", "Links Wrapped", "See Who Shared It",
                      "Nudge Friends About Links They Haven't Seen", "Swipe Through Your Queue",
                      "React With Any Emoji", "Save Your Favorites"] {
            app.buttons["featureTour.continue"].tap()
            XCTAssert(waitForTitle(title))
        }
        app.buttons["featureTour.action.favorites"].tap()
        XCTAssert(app.navigationBars["Favorites"].waitForExistence(timeout: 20))
        XCTAssert(app.staticTexts["Make Links Yours"].waitForNonExistence(timeout: 20))
    }

    func testSkippingMarksAllFeaturesSeen() {
        launch(reset: true)
        waitForNotificationsBeforeFeatureTour(in: app) { capture("Notification prompt before feature tour") }
        XCTAssert(waitForTitle("Make Links Yours"))
        app.buttons["featureTour.skip"].tap()
        XCTAssert(app.staticTexts["Make Links Yours"].waitForNonExistence(timeout: 20))
        app.quit()
        app = XCUIApplication()
        launch(reset: false)
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Make Links Yours"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Send Today's Links Together"].exists)
        XCTAssertFalse(app.staticTexts["See Who Shared It"].exists)
        XCTAssertFalse(app.staticTexts["Nudge Friends About Links They Haven't Seen"].exists)
        XCTAssertFalse(app.staticTexts["Swipe Through Your Queue"].exists)
        XCTAssertFalse(app.staticTexts["React With Any Emoji"].exists)
        XCTAssertFalse(app.staticTexts["Save Your Favorites"].exists)
        XCTAssertFalse(app.staticTexts["Invite Friends to a Chat"].exists)
        XCTAssertFalse(app.staticTexts["Get a Daily Catch-Up"].exists)
    }

    func testRecoversAutomaticallyWhenPresentationDoesNotAppear() {
        launch(reset: true, dropPresentation: "once")
        waitForNotificationsBeforeFeatureTour(in: app)
        XCTAssert(waitForTitle("Make Links Yours"))
    }

    func testWhatsNewRecoversAfterDroppedAutomaticPresentation() {
        launch(reset: true, dropPresentation: "until-replay")
        let account = app.buttons["account"]
        XCTAssert(account.waitForExistence(timeout: 20))
        waitForDroppedFeatureTour(in: account)
        XCTAssertFalse(app.buttons["featureTour.skip"].exists)
        account.tap()
        let replay = app.buttons["profile.whatsNew"]
        for _ in 0..<6 where !(replay.exists && replay.isHittable) { app.swipeUp() }
        XCTAssert(replay.isHittable)
        replay.tap()
        XCTAssert(waitForTitle("Make Links Yours"), "What's New did not recover the dropped sheet")
        XCTAssertFalse(app.navigationBars["Profile"].exists)
        capture("What's New recovered the dropped sheet")
    }

    func testFeatureTourResumesAfterDismissingNewLink() {
        launch(reset: true, openNewLink: true)
        let cancel = app.navigationBars["New Link"].buttons["Cancel"]
        XCTAssert(cancel.waitForExistence(timeout: 20), "New Link did not open on launch")
        XCTAssertFalse(app.buttons["featureTour.skip"].exists, "feature tour opened over New Link")
        cancel.tap()
        XCTAssert(cancel.waitForNonExistence(timeout: 20), "New Link did not dismiss")

        waitForNotificationsBeforeFeatureTour(in: app)
        XCTAssert(waitForTitle("Make Links Yours"))
        app.buttons["featureTour.skip"].tap()
        XCTAssert(app.buttons["featureTour.skip"].waitForNonExistence(timeout: 20))
    }

    func testFeatureTourResumesAfterDismissingSwipeThrough() throws {
        let link = try server.add("https://links-e2e.invalid/\(UUID().uuidString.lowercased())", as: server.friend)
        defer { try? server.delete(link.id, as: server.friend) }
        launch(reset: true, swipeQueueLinkID: link.id)
        let close = app.buttons["swipeQueue.close"]
        XCTAssert(close.waitForExistence(timeout: 20), "Swipe Through did not open on launch")
        XCTAssert(app.descendants(matching: .any)["swipeQueue.card.\(link.id)"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["featureTour.skip"].exists, "feature tour opened over Swipe Through")
        close.tap()
        XCTAssert(close.waitForNonExistence(timeout: 20), "Swipe Through did not dismiss")

        waitForNotificationsBeforeFeatureTour(in: app)
        XCTAssert(waitForTitle("Make Links Yours"))
        app.buttons["featureTour.skip"].tap()
        XCTAssert(app.buttons["featureTour.skip"].waitForNonExistence(timeout: 20))
    }

    private func launch(reset: Bool, dropPresentation: String? = nil, openNewLink: Bool = false,
                        swipeQueueLinkID: Int? = nil) {
        app.launchEnvironment = [
            "LINKS_TEST_NOTIFICATION_TIMEOUT_SECONDS": "150",
            "LINKS_SERVER_URL": server.url.absoluteString,
            "LINKS_DEV_TOKEN": server.me,
            "LINKS_COMPLETE_ONBOARDING": "1",
            "LINKS_TEST_HIDE_GESTURE_TIPS": "1",
        ]
        if reset { app.launchEnvironment["LINKS_RESET_FEATURE_TOURS"] = "1" }
        app.launchEnvironment["LINKS_TEST_DROP_FEATURE_TOUR_PRESENTATION"] = dropPresentation
        if openNewLink { app.launchEnvironment["LINKS_TEST_OPEN_NEW_LINK_ON_LAUNCH"] = "1" }
        if let swipeQueueLinkID { app.launchEnvironment["LINKS_TEST_OPEN_SWIPE_QUEUE_ON_LAUNCH"] = String(swipeQueueLinkID) }
        app.prepareToQuit()
        app.launch()
    }

    private func waitForDroppedFeatureTour(in account: XCUIElement) {
        let springBoard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springBoard.alerts.buttons["Allow"]
        let deadline = ContinuousClock.now + .seconds(180)
        var answeredPrompt = false
        repeat {
            if account.value as? String == "Feature tour presentation dropped" { return }
            if !answeredPrompt, allow.exists {
                allow.tap()
                answeredPrompt = true
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while ContinuousClock.now < deadline
        XCTFail("automatic feature tour presentation was not dropped")
    }

    private func tapWhatsNew() {
        let replay = app.buttons["profile.whatsNew"]
        XCTAssert(app.navigationBars["Profile"].waitForExistence(timeout: 30))
        let deadline = ContinuousClock.now + .seconds(120)
        var scrollingDown = true
        repeat {
            let window = self.app.windows.firstMatch.frame
            let list = self.app.collectionViews.containing(.button, identifier: "profile.whatsNew").firstMatch
            var viewport = (list.exists ? list.frame.intersection(window) : window).insetBy(dx: 8, dy: 8)
            let navigation = app.navigationBars["Profile"].frame
            viewport = viewport.intersection(CGRect(x: window.minX, y: navigation.maxY,
                                                    width: window.width, height: max(0, window.maxY - navigation.maxY)))
            if replay.exists {
                let frame = replay.frame
                if !frame.isEmpty, !frame.isNull, !frame.isInfinite {
                    if viewport.contains(frame) {
                        app.coordinate(withNormalizedOffset: .zero)
                            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                        return
                    }
                    scrollingDown = frame.midY > viewport.midY
                }
            }
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (scrollingDown ? 0.7 : 0.3)))
            let end = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (scrollingDown ? 0.3 : 0.7)))
            start.press(forDuration: 0.1, thenDragTo: end)
        } while ContinuousClock.now < deadline
        XCTFail("What's New did not enter the Profile viewport within 120 seconds: \(app.debugDescription)")
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
        let deadline = ContinuousClock.now + .seconds(180)
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
