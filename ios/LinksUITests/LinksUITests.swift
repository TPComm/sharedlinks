import XCTest

/// End to end: the real app in a Simulator against a real server (ios/scripts/ui-tests.sh).
/// Every test shares that server, so each seeds its own links (unique URLs) and deletes them after.
@MainActor
final class LinksUITests: XCTestCase {
    private var server: LinksServer!
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        server = try LinksServer.fromEnvironment()
    }

    // MARK: Inbox

    func testSignedInLaunchShowsTheInbox() throws {
        launch()
        XCTAssert(app.navigationBars["To Watch"].exists)
        for tab in ["To Watch", "Watched", "Sent", "Search"] {
            XCTAssert(app.tabBars.buttons[tab].exists, "no \(tab) tab")
        }
        XCTAssert(app.buttons["newLink"].exists)
        XCTAssertFalse(app.buttons["signIn"].exists)
    }

    func testFriendsLinkShowsUpInToWatchWithItsNote() throws {
        // No "Friend" in the note, so the check for the sender's name below can't pass through it.
        let note = "Watch this \(shortID())"
        let link = try seed(by: server.friend, note: note)
        launch()
        let row = waitForRow(link, in: "toWatch")
        XCTAssert(row.label.contains(note), row.label)
        XCTAssert(row.label.contains("Friend"), row.label)
        XCTAssert(row.label.contains("Not watched"), row.label)
    }

    func testOpeningALinkMarksItWatched() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        row.tap() // hands the link to Safari, which takes over the screen
        let me = try server.state(as: server.me).me
        try server.eventually("seen by me") { try server.state(as: server.friend).link(link.id)?.seen[me] }
    }

    func testMarkingWatchedMovesItToWatchedAndTellsTheServer() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        row.swipeRight()
        app.collectionViews["links.toWatch"].buttons["Watched"].tap()
        XCTAssert(row.waitForNonExistence(timeout: 5), "still in To Watch")

        app.tabBars.buttons["Watched"].tap()
        let watched = self.row(link, in: "watched")
        XCTAssert(watched.waitForExistence(timeout: 5))
        XCTAssertFalse(watched.label.contains("Not watched"), watched.label)

        let me = try server.state(as: server.me).me
        try server.eventually("seen by me") { try server.state(as: server.friend).link(link.id)?.seen[me] }
    }

    func testSentShowsWhenTheFriendHasWatchedIt() throws {
        let link = try seed(by: server.me, note: "Sent \(shortID())")
        launch()
        app.tabBars.buttons["Sent"].tap()
        let row = waitForRow(link, in: "sent")
        XCTAssert(row.label.contains("Not seen yet"), row.label)

        try server.setSeen(link.id, true, as: server.friend)
        app.collectionViews["links.sent"].swipeDown() // pull to refresh
        waitFor(row, labelContaining: "Seen by Friend")
    }

    func testSearchFindsALinkByItsNote() throws {
        let word = "zebra\(shortID())"
        let match = try seed(by: server.friend, note: "Look, a \(word)")
        let other = try seed(by: server.friend, note: "Something else")
        launch()
        app.tabBars.buttons["Search"].tap()
        waitForRow(other, in: "all")

        // The search field stays tucked under the title until the list is pulled down.
        app.collectionViews["links.all"].swipeDown()
        let field = app.searchFields["Titles, people, notes"]
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(word)
        XCTAssert(row(match, in: "all").waitForExistence(timeout: 5))
        XCTAssert(row(other, in: "all").waitForNonExistence(timeout: 5), "a link that doesn't match")
    }

    func testWidgetDeepLinkOpensTheNewLinkSheet() throws {
        launch()
        app.open(URL(string: "sharedlinks://add")!)
        XCTAssert(app.textFields["addLink.text"].waitForExistence(timeout: 10))
        XCTAssert(app.buttons["addLink.send"].exists)
        XCTAssertFalse(app.buttons["addLink.send"].isEnabled, "Send with nothing to send")
    }

    // MARK: Changes

    func testAddingALinkInTheAppSendsIt() throws {
        launch()
        let url = uniqueURL()
        let note = "Added in the app \(shortID())"
        app.buttons["newLink"].tap()
        let text = app.textFields["addLink.text"]
        XCTAssert(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText(url)
        let noteField = app.textFields["addLink.note"]
        noteField.tap()
        noteField.typeText(note)
        app.buttons["addLink.send"].tap()

        // The sheet closes and the app switches to Sent, which has the new link.
        XCTAssert(text.waitForNonExistence(timeout: 10), "the New Link sheet stayed open")
        let link = try server.eventually("the new link") {
            try server.state(as: server.friend).links.first { $0.url == url }
        }
        deleteAfterwards(link.id)
        let me = try server.state(as: server.me).me
        XCTAssertEqual(link.note, note)
        XCTAssertEqual(link.addedBy, me)
        XCTAssert(app.tabBars.buttons["Sent"].isSelected)
        XCTAssert(row(link, in: "sent").waitForExistence(timeout: 5))
    }

    func testServerErrorsAreShown() throws {
        launch()
        app.buttons["newLink"].tap()
        let text = app.textFields["addLink.text"]
        XCTAssert(text.waitForExistence(timeout: 5))
        text.tap()
        // A bare domain: the app finds a link in it, but the server wants a path and refuses it.
        text.typeText("example.com")
        app.buttons["addLink.send"].tap()

        let alert = app.alerts["Couldn't Do That"]
        XCTAssert(alert.waitForExistence(timeout: 10))
        XCTAssert(alert.staticTexts["That doesn't look like a link."].exists)
        alert.buttons["OK"].tap()
        XCTAssert(alert.waitForNonExistence(timeout: 5))

        // The sheet stays, with what was typed, so it can be fixed and sent again.
        XCTAssert(text.waitForExistence(timeout: 2), "the New Link sheet closed")
        XCTAssertEqual(text.value as? String, "example.com")
    }

    func testReactingAndEditingTheNote() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        let me = try server.state(as: server.me).me

        menu(on: row, item: "❤️").tap()
        try server.eventually("my reaction") {
            try server.state(as: server.friend).link(link.id)?.reactions[me] == "❤️" ? true : nil
        }
        waitFor(row, labelContaining: "❤️ You")

        let note = "Watch with sound \(shortID())"
        menu(on: row, item: "Add Note").tap()
        let alert = app.alerts["Add Note"]
        let field = alert.textFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        // The alert focuses its field itself, but not always in time on a slow CI Simulator.
        field.tap()
        field.typeText(note)
        alert.buttons["Save"].tap()
        try server.eventually("the note") {
            try server.state(as: server.friend).link(link.id)?.note == note ? true : nil
        }
        waitFor(row, labelContaining: note)
    }

    func testReactingFromTheFeed() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        let me = try server.state(as: server.me).me

        let react = app.buttons["react.\(link.id)"]
        XCTAssertEqual(react.label, "React")
        react.tap()
        let heart = app.buttons["reaction.❤️"]
        XCTAssert(heart.waitForExistence(timeout: 5), "no reaction bar")
        heart.tap()
        XCTAssert(heart.waitForNonExistence(timeout: 5), "the reaction bar stayed open")
        waitFor(row, labelContaining: "❤️ You")
        try server.eventually("my reaction") {
            try server.state(as: server.friend).link(link.id)?.reactions[me] == "❤️" ? true : nil
        }
        XCTAssertEqual(react.label, "Your reaction, ❤️")
        // The react button sits on the row, but tapping it mustn't open (and so watch) the link.
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertNil(try server.state(as: server.friend).link(link.id)?.seen[me], "the link was opened")

        // Picking the same one again takes it back.
        react.tap()
        XCTAssert(heart.waitForExistence(timeout: 5))
        heart.tap()
        try server.eventually("no reaction") {
            try server.state(as: server.friend).link(link.id)?.reactions[me] == nil ? true : nil
        }
        XCTAssertEqual(react.label, "React")
    }

    func testDeletingALinkRemovesItForEveryone() throws {
        let link = try seed(by: server.me)
        launch()
        app.tabBars.buttons["Sent"].tap()
        let row = waitForRow(link, in: "sent")
        row.swipeLeft()
        app.collectionViews["links.sent"].buttons["Delete"].tap()

        let confirm = app.sheets.buttons["Delete"]
        XCTAssert(confirm.waitForExistence(timeout: 5), "no delete confirmation")
        confirm.tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
        try server.eventually("the link gone") {
            try server.state(as: server.friend).link(link.id) == nil ? true : nil
        }
    }

    // MARK: Account

    func testSigningOutReturnsToSignIn() throws {
        launch(as: server.spare)
        app.buttons["account"].tap()
        app.buttons["Sign Out"].tap()
        let signIn = app.buttons["signIn"]
        XCTAssert(signIn.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertEqual(app.buttons["Create Account"].frame.width, signIn.frame.width, accuracy: 1,
                       "the sign-in buttons differ in width")
        // The server ended that session too.
        try server.eventually("the session ended") {
            try server.status("GET", "api/state", as: server.spare) == 401 ? true : nil
        }
    }

    func testDeletingTheAccountSignsOutAndLeavesItsLinksFromDeletedUser() throws {
        // An account of its own: deleting "Me" would sign every later test out.
        let sent = try seed(by: server.deletable, note: "Mine \(shortID())")
        let friends = try seed(by: server.friend)
        try server.setSeen(friends.id, true, as: server.deletable)
        let deleted = try server.state(as: server.deletable).me
        launch(as: server.deletable)
        app.tabBars.buttons["Sent"].tap()
        waitForRow(sent, in: "sent") // so the warning can count it

        app.buttons["account"].tap()
        app.buttons["Delete Account…"].tap()
        let alert = app.alerts["Delete Your Account?"]
        XCTAssert(alert.waitForExistence(timeout: 5), "no confirmation")
        let warning = NSPredicate(format: "label CONTAINS %@", "The link you sent stays for your friends, from “Deleted user”.")
        XCTAssert(alert.staticTexts.matching(warning).firstMatch.exists, "the warning doesn't say what goes")
        alert.buttons["Delete Account"].tap()

        XCTAssert(app.buttons["signIn"].waitForExistence(timeout: 15), "not back at sign-in")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertEqual(try server.status("GET", "api/state", as: server.deletable), 401)
        let state = try server.state(as: server.friend)
        XCTAssertEqual(try XCTUnwrap(state.link(sent.id), "the link they sent went").addedBy, "deleted")
        let kept = try XCTUnwrap(state.link(friends.id), "the friend's link went")
        XCTAssertNil(kept.seen[deleted], "their watched mark is still there")

        // The friend sees it as from "Deleted user".
        launch(as: server.friend)
        waitFor(waitForRow(sent, in: "toWatch"), labelContaining: "Deleted user")
    }

    // MARK: Helpers

    /// Launches signed in (DEBUG builds take a session token from LINKS_DEV_TOKEN).
    private func launch(as token: String? = nil) {
        app.launchEnvironment = [
            "LINKS_SERVER_URL": server.url.absoluteString,
            "LINKS_DEV_TOKEN": token ?? server.me,
            "LINKS_UI_TESTS": "1", // no badge-permission prompt (see AppModel.requestBadgePermission)
        ]
        app.launch()
        XCTAssert(app.tabBars.buttons["To Watch"].waitForExistence(timeout: 20), "no inbox")
    }

    private func row(_ link: LinksServer.Link, in list: String) -> XCUIElement {
        app.collectionViews["links.\(list)"].buttons["link.\(link.id)"]
    }

    /// The row of a link the server already had at launch. If the launch fetch hasn't landed yet
    /// (a slow CI Simulator), pull to refresh once, as a person would, before failing.
    @discardableResult
    private func waitForRow(_ link: LinksServer.Link, in list: String) -> XCUIElement {
        let row = row(link, in: list)
        if !row.waitForExistence(timeout: 10) {
            app.collectionViews["links.\(list)"].swipeDown()
            XCTAssert(row.waitForExistence(timeout: 10), "link \(link.id) never showed up in \(list)")
        }
        return row
    }

    /// Long-presses a row for its context menu and returns one of the menu's buttons.
    private func menu(on row: XCUIElement, item: String) -> XCUIElement {
        let button = app.buttons[item]
        // Picking a reaction (a palette) leaves the menu open.
        if !button.exists {
            row.press(forDuration: 1.2)
        }
        XCTAssert(button.waitForExistence(timeout: 5), "no \(item) in the context menu")
        return button
    }

    private func waitFor(_ element: XCUIElement, labelContaining text: String, timeout: TimeInterval = 15) {
        let label = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        wait(for: [label], timeout: timeout)
    }

    /// ".invalid" never resolves, so the server's preview fetch fails at once, even online.
    private func uniqueURL() -> String { "https://links-e2e.invalid/\(UUID().uuidString.lowercased())" }

    private func shortID() -> String { String(UUID().uuidString.prefix(8)) }

    private func seed(by token: String, note: String = "") throws -> LinksServer.Link {
        let link = try server.add(uniqueURL(), note: note, as: token)
        deleteAfterwards(link.id)
        return link
    }

    private func deleteAfterwards(_ id: Int) {
        let server = server!
        addTeardownBlock { try? server.delete(id, as: server.friend) }
    }
}
