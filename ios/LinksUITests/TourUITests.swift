import XCTest

/// The welcome tour (#10) and its share-sheet step (#9), as on a first launch. The other UI tests
/// launch with LINKS_UI_TESTS=1, which skips the tour, the tips and the notification prompt; this one
/// doesn't, and LINKS_RESET_ONBOARDING=1 makes its first launch a first launch every time.
@MainActor
final class TourUITests: XCTestCase {
    private var server: LinksServer!
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        server = try LinksServer.fromEnvironment()
    }

    func testTheTourShowsOnceAndComesBackFromTheProfile() throws {
        // A friend's link, so the gesture tips have a row in To Watch to sit on.
        let link = try server.add("https://links-e2e.invalid/\(UUID().uuidString.lowercased())", as: server.friend)
        let server = server!
        addTeardownBlock { try? server.delete(link.id, as: server.friend) }
        launch(firstRun: true)

        XCTAssert(waitForPage("Welcome to Links", timeout: 20), "no tour on the first launch")
        XCTAssert(app.descendants(matching: .any)["trademarkNotice"].exists, "no trademark notice in the tour")
        app.buttons["tour.continue"].tap()

        // The share-sheet step: practise in a real share sheet, through the real Share Extension.
        XCTAssert(waitForPage("Add Links to Your Share Sheet"))
        app.buttons["tour.tryIt"].tap()
        let sheet = app.collectionViews["activityCollectionView"]
        XCTAssert(sheet.waitForExistence(timeout: 30), "no share sheet")
        if !sheet.cells["Links"].waitForExistence(timeout: 10) {
            // Not in the row of apps on this device: it's behind More, as the steps say.
            sheet.cells["More"].tap()
        }
        app.cells["Links"].firstMatch.tap()
        // Practice mode is the real compose screen (#54): a note field and Send, nothing sent.
        XCTAssert(app.descendants(matching: .any)["share.practiceIntro"].waitForExistence(timeout: 30),
                  "the Share Extension didn't open in practice mode")
        let note = app.textFields["share.note"]
        XCTAssert(note.exists, "no note field in practice mode")
        type("Practice note", into: note)
        app.buttons["share.send"].tap()
        XCTAssert(app.staticTexts["That's It"].waitForExistence(timeout: 10), "practice Send didn't say it worked")
        // The extension told the app (App Group defaults), and the step ticked itself off.
        XCTAssert(waitForPage("Links Is in Your Share Sheet"), "the step didn't notice")
        app.buttons["tour.continue"].tap()

        XCTAssert(waitForPage("Your Inbox, Sorted"))
        app.buttons["tour.continue"].tap()

        XCTAssert(waitForPage("A Couple of Extras"))
        XCTAssertFalse(app.buttons["tour.skip"].exists, "Skip on the last page")
        app.buttons["tour.done"].tap()
        allowNotificationsIfAsked()

        // The inbox, with the gesture tips on the friend's link, one after another.
        XCTAssert(app.tabBars.buttons["To Watch"].waitForExistence(timeout: 20))
        for tip in ["React to a Link", "Swipe Right to Mark Watched", "Touch and Hold for More"] {
            XCTAssert(app.staticTexts[tip].waitForExistence(timeout: 20), "no \"\(tip)\" tip")
            closeTip()
            XCTAssert(app.staticTexts[tip].waitForNonExistence(timeout: 20), "\"\(tip)\" stayed")
        }

        // Once is enough: neither the tour nor the tips come back on the next launch.
        app.terminate()
        launch(firstRun: false)
        XCTAssert(app.tabBars.buttons["To Watch"].waitForExistence(timeout: 20), "no inbox")
        XCTAssertFalse(app.staticTexts["Welcome to Links"].waitForExistence(timeout: 3), "the tour came back")
        XCTAssertFalse(app.staticTexts["React to a Link"].exists, "a tip came back")

        // ...until it's asked for.
        app.buttons["account"].tap()
        app.buttons["Show Tour Again"].tap()
        XCTAssert(waitForPage("Welcome to Links"), "Show Tour Again didn't")
        app.buttons["tour.skip"].tap()
        XCTAssert(app.staticTexts["Welcome to Links"].waitForNonExistence(timeout: 20), "Skip didn't close the tour")

        // Straight to the share-sheet step, which remembers it's done.
        app.buttons["account"].tap()
        app.buttons["How to Share to Links"].tap()
        XCTAssert(waitForPage("Links Is in Your Share Sheet"), "How to Share to Links didn't")
        app.buttons["tour.skip"].tap()
        XCTAssert(app.staticTexts["Links Is in Your Share Sheet"].waitForNonExistence(timeout: 20))
    }

    // MARK: Helpers

    private func launch(firstRun: Bool) {
        app.launchEnvironment = [
            "LINKS_SERVER_URL": server.url.absoluteString,
            "LINKS_DEV_TOKEN": server.me,
        ]
        if firstRun { app.launchEnvironment["LINKS_RESET_ONBOARDING"] = "1" }
        app.launch()
    }

    /// The pages either side of the current one are laid out too, so a page counts once its title
    /// can be tapped. CI's Simulator can take 10s or more per tap and page turn, so waits are long;
    /// they cost nothing when the page is already there.
    private func waitForPage(_ title: String, timeout: TimeInterval = 20) -> Bool {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"),
                                              object: app.staticTexts[title])
        return XCTWaiter.wait(for: [shown], timeout: timeout) == .completed
    }

    /// The notification prompt comes when the tour ends, unless this Simulator has answered it before.
    private func allowNotificationsIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    /// A popover tip's close button.
    private func closeTip() {
        let close = app.popovers.buttons["Close"].firstMatch
        XCTAssert(close.waitForExistence(timeout: 20), "no close button on the tip")
        close.tap()
    }
}
