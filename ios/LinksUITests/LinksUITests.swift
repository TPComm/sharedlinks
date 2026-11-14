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

    func testLongPressOpenStillMarksItWatched() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        // The fast path: straight out to the link (Safari, for these .invalid URLs), marking it watched.
        let me = try server.state(as: server.me).me
        menu(on: row, item: "Open in Browser").tap()
        try server.eventually(timeout: 20, "seen by me") { try server.state(as: server.friend).link(link.id)?.seen[me] }
        XCTAssert(safari.wait(for: .runningForeground, timeout: safariLaunch), "the link didn't open")

        // Back in the app it has left To Watch, and Watched has it (not an empty list: #7).
        app.activate()
        XCTAssert(row.waitForNonExistence(timeout: 10), "still in To Watch")
        app.tabBars.buttons["Watched"].tap()
        XCTAssert(self.row(link, in: "watched").waitForExistence(timeout: 5), "not in Watched")
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
        type(word, into: field)
        XCTAssert(row(match, in: "all").waitForExistence(timeout: 5))
        XCTAssert(row(other, in: "all").waitForNonExistence(timeout: 5), "a link that doesn't match")
    }

    func testWidgetLinkOpensTheLinksPage() throws {
        let link = try seed(by: server.friend)
        launch()
        waitForRow(link, in: "toWatch")
        app.tabBars.buttons["Sent"].tap() // the page opens on the tab whose list has the link
        app.open(URL(string: "sharedlinks://open/\(link.id)")!)
        XCTAssert(page(link).waitForExistence(timeout: 10), "no page for the link")
        XCTAssert(app.tabBars.buttons["To Watch"].isSelected)
        // It stays in the app, and doesn't count as watched.
        XCTAssertEqual(app.state, .runningForeground)
        let me = try server.state(as: server.me).me
        XCTAssertNil(try server.state(as: server.friend).link(link.id)?.seen[me], "the widget marked it watched")
    }

    func testWidgetDeepLinkOpensTheNewLinkSheet() throws {
        launch()
        app.open(URL(string: "sharedlinks://add")!)
        XCTAssert(app.textFields["addLink.text"].waitForExistence(timeout: 10))
        XCTAssert(app.buttons["addLink.send"].exists)
        XCTAssertFalse(app.buttons["addLink.send"].isEnabled, "Send with nothing to send")
    }

    // MARK: Link pages

    func testTappingALinkShowsItsPage() throws {
        let note = "On the page \(shortID())"
        let link = try seed(by: server.friend, note: note)
        launch()
        waitForRow(link, in: "toWatch").tap()
        let page = page(link)
        XCTAssert(page.waitForExistence(timeout: 5), "no page for the link")
        XCTAssert(page.staticTexts[note].exists, "no note")
        XCTAssert(page.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "From Friend")).firstMatch.exists,
                  "no sender")
        XCTAssertEqual(app.buttons["linkPage.watch"].label, "Open in Browser")
        let me = try server.state(as: server.me).me
        XCTAssertNil(try server.state(as: server.friend).link(link.id)?.seen[me], "showing the page marked it watched")

        // React and mark it watched from the page, which stays. (Scrolled first: on an iPhone the
        // reactions start just above the floating tab bar.)
        page.swipeUp()
        app.buttons["reaction.😂"].tap()
        try server.eventually("my reaction") {
            try server.state(as: server.friend).link(link.id)?.reactions[me] == "😂" ? true : nil
        }
        app.buttons["linkPage.markWatched"].tap()
        try server.eventually("seen by me") { try server.state(as: server.friend).link(link.id)?.seen[me] }
        XCTAssert(app.buttons["linkPage.markNotWatched"].waitForExistence(timeout: 5))
        XCTAssert(page.exists, "marking it watched left the page")

        // Back on the list, it has gone from To Watch.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssert(page.waitForNonExistence(timeout: 5), "still on the page")
        XCTAssert(app.collectionViews["links.toWatch"].waitForExistence(timeout: 5))
        XCTAssertFalse(row(link, in: "toWatch").exists, "still in To Watch")
    }

    /// The issue this page exists for (#7): watch it, come back, and you're on its page to react
    /// and mark it watched, instead of on a list it has already left.
    func testComingBackFromWatchingLandsOnTheLinksPage() throws {
        let link = try seed(by: server.friend)
        launch()
        waitForRow(link, in: "toWatch").tap()
        XCTAssert(page(link).waitForExistence(timeout: 5), "no page for the link")
        XCTAssertFalse(app.staticTexts["Watched it?"].exists, "asked before watching")

        app.buttons["linkPage.watch"].tap()
        XCTAssert(safari.wait(for: .runningForeground, timeout: safariLaunch), "the link didn't open")
        app.activate()
        XCTAssert(page(link).waitForExistence(timeout: 10), "not on the link's page")
        XCTAssert(app.staticTexts["Watched it?"].waitForExistence(timeout: 5), "no Watched it? prompt")
        let me = try server.state(as: server.me).me
        XCTAssertNil(try server.state(as: server.friend).link(link.id)?.seen[me], "opening it marked it watched")

        app.buttons["linkPage.markWatched"].tap()
        try server.eventually("seen by me") { try server.state(as: server.friend).link(link.id)?.seen[me] }
        XCTAssert(app.staticTexts["Watched it?"].waitForNonExistence(timeout: 5), "still asking")
    }

    func testSentLinksPageShowsWhoHasSeenIt() throws {
        let link = try seed(by: server.me)
        launch()
        app.tabBars.buttons["Sent"].tap()
        waitForRow(link, in: "sent").tap()
        let page = page(link)
        XCTAssert(page.waitForExistence(timeout: 5), "no page for the link")
        XCTAssert(page.staticTexts["Seen By"].exists)
        XCTAssertFalse(app.buttons["linkPage.markWatched"].exists, "offered to mark my own link watched")

        let receipt = page.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Friend")).firstMatch
        XCTAssert(receipt.waitForExistence(timeout: 5), "Friend isn't listed")
        XCTAssert(receipt.label.contains("Not yet"), receipt.label)

        try server.setSeen(link.id, true, as: server.friend)
        // The page follows the inbox, which the app polls every few seconds.
        waitFor(receipt, labelContaining: "now")
    }

    // MARK: Changes

    func testAddingALinkInTheAppSendsIt() throws {
        launch()
        let url = uniqueURL()
        let note = "Added in the app \(shortID())"
        app.buttons["newLink"].tap()
        let text = app.textFields["addLink.text"]
        XCTAssert(text.waitForExistence(timeout: 5))
        type(url, into: text)
        let noteField = app.textFields["addLink.note"]
        type(note, into: noteField)
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
        // A bare domain: the app finds a link in it, but the server wants a path and refuses it.
        type("example.com", into: text)
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
        // On my own link: only the sender can write a link's note.
        let link = try seed(by: server.me)
        launch()
        app.tabBars.buttons["Sent"].tap()
        let row = waitForRow(link, in: "sent")
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
        type(note, into: field)
        alert.buttons["Save"].tap()
        try server.eventually("the note") {
            try server.state(as: server.friend).link(link.id)?.note == note ? true : nil
        }
        waitFor(row, labelContaining: note)
    }

    func testAFriendsLinkHasNoNoteEditing() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        XCTAssert(menu(on: row, item: "Report…").exists)
        XCTAssertFalse(app.buttons["Add Note"].exists)
    }

    // MARK: Reports and blocks

    func testReportingALinkHidesItForMeOnly() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        menu(on: row, item: "Report…").tap()
        let reason = app.buttons["Offensive or Inappropriate"]
        XCTAssert(reason.waitForExistence(timeout: 5), "no report reasons")
        reason.tap()
        XCTAssert(row.waitForNonExistence(timeout: 5), "still in To Watch")
        try server.eventually("hidden for me") { try server.state(as: server.me).link(link.id) == nil ? true : nil }
        XCTAssertNotNil(try server.state(as: server.friend).link(link.id), "hidden for the sender too")
    }

    func testBlockingAndUnblockingSomeone() throws {
        let link = try seed(by: server.friend)
        let friendID = try server.state(as: server.friend).me
        let api = server!
        addTeardownBlock { try? api.unblock(friendID, as: api.me) }
        launch()
        let row = waitForRow(link, in: "toWatch")
        menu(on: row, item: "Block Friend…").tap()
        let block = app.alerts["Block Friend?"].buttons["Block"]
        XCTAssert(block.waitForExistence(timeout: 5), "no block confirmation")
        block.tap()
        XCTAssert(row.waitForNonExistence(timeout: 5), "still in To Watch")
        try server.eventually("blocked") { try server.state(as: server.me).blocked == [friendID] ? true : nil }

        app.buttons["account"].tap()
        app.buttons["Blocked People…"].tap()
        let unblock = app.buttons["unblock.\(friendID)"]
        XCTAssert(unblock.waitForExistence(timeout: 5), "not under Blocked People")
        unblock.tap()
        XCTAssert(app.staticTexts["No One Blocked"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssert(row.waitForExistence(timeout: 10), "their link didn't come back")
        XCTAssertEqual(try server.state(as: server.me).blocked, [])
    }

    func testInvitingAFriendMakesALinkToSendAndCancelsIt() throws {
        launch()
        app.buttons["account"].tap()
        app.buttons["People"].tap()
        let invite = app.buttons["inviteFriend"]
        XCTAssert(invite.waitForExistence(timeout: 5), "no Invite a Friend")
        invite.tap()
        app.buttons["createInvite"].tap()
        XCTAssert(app.buttons["sendInvite"].waitForExistence(timeout: 10), "no invite link to send")
        app.buttons["Done"].firstMatch.tap()
        let pending = app.staticTexts["Invite link"]
        XCTAssert(pending.waitForExistence(timeout: 5), "not under Invited")
        pending.swipeLeft()
        app.buttons["Cancel Invite"].tap()
        XCTAssert(pending.waitForNonExistence(timeout: 5), "still under Invited")
        app.buttons["Done"].tap()
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
        // The react button sits on the row, but tapping it mustn't open the link's page.
        XCTAssertFalse(page(link).exists, "the link's page opened")
        XCTAssert(row.exists)

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
        XCTAssert(app.descendants(matching: .any)["Privacy Policy"].waitForExistence(timeout: 5),
                  "no Privacy Policy in the account menu")
        app.buttons["About Links"].tap()
        let about = app.alerts.firstMatch
        XCTAssert(about.waitForExistence(timeout: 5), "About Links didn't open")
        XCTAssert(about.label.hasPrefix("Links "), "the About title has no version: \(about.label)")
        let fullNotice = about.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                                  "Facebook is a trademark of Meta Platforms, Inc."))
        XCTAssert(fullNotice.firstMatch.exists, "About Links doesn't list every platform's owner")
        about.buttons["OK"].tap()
        XCTAssert(about.waitForNonExistence(timeout: 5))
        app.buttons["account"].tap()
        let signOut = app.buttons["Sign Out"]
        XCTAssert(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        let signIn = app.buttons["signIn"]
        XCTAssert(signIn.waitForExistence(timeout: 10))
        XCTAssert(app.descendants(matching: .any)["signIn.privacy"].exists, "no Privacy Policy on the sign-in screen")
        XCTAssert(app.descendants(matching: .any)["trademarkNotice"].exists, "no trademark notice on the sign-in screen")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertEqual(app.buttons["Create Account"].frame.width, signIn.frame.width, accuracy: 1,
                       "the sign-in buttons differ in width")
        // The server ended that session too.
        try server.eventually("the session ended") {
            try server.status("GET", "api/state", as: server.spare) == 401 ? true : nil
        }
    }

    func testDeletingTheAccountSignsOutAndDeletesTheLinksItSent() throws {
        // An account of its own: deleting "Me" would sign every later test out.
        let sent = try seed(by: server.deletable, note: "Mine \(shortID())")
        let friends = try seed(by: server.friend)
        let others = try seed(by: server.me)
        try server.setSeen(friends.id, true, as: server.deletable)
        let deleted = try server.state(as: server.deletable).me
        launch(as: server.deletable)
        app.tabBars.buttons["Sent"].tap()
        waitForRow(sent, in: "sent") // so the warning can count it

        app.buttons["account"].tap()
        app.buttons["Delete Account…"].tap()
        let alert = app.alerts["Delete Your Account?"]
        XCTAssert(alert.waitForExistence(timeout: 5), "no confirmation")
        let warning = NSPredicate(format: "label CONTAINS %@", "the link you sent and its note (your friends lose it too)")
        XCTAssert(alert.staticTexts.matching(warning).firstMatch.exists, "the warning doesn't say what goes")
        alert.buttons["Delete Account"].tap()

        XCTAssert(app.buttons["signIn"].waitForExistence(timeout: 15), "not back at sign-in")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertEqual(try server.status("GET", "api/state", as: server.deletable), 401)
        let state = try server.state(as: server.friend)
        XCTAssertNil(state.link(sent.id), "the link they sent is still there")
        let kept = try XCTUnwrap(state.link(friends.id), "the friend's link went")
        XCTAssertNil(kept.seen[deleted], "their watched mark is still there")

        // The friend no longer has it to watch.
        launch(as: server.friend)
        waitForRow(others, in: "toWatch")
        XCTAssertFalse(row(sent, in: "toWatch").exists, "the friend still has it")
    }

    // MARK: Helpers

    /// Launches signed in (DEBUG builds take a session token from LINKS_DEV_TOKEN), on the inbox.
    private func launch(as token: String? = nil) {
        app.launchEnvironment = [
            "LINKS_SERVER_URL": server.url.absoluteString,
            "LINKS_DEV_TOKEN": token ?? server.me,
            // No notification prompt (AppModel.requestNotificationPermission), and no pages restored
            // from an earlier test (RootView.restoreNavigation).
            "LINKS_UI_TESTS": "1",
        ]
        app.launch()
        XCTAssert(app.tabBars.buttons["To Watch"].waitForExistence(timeout: 20), "no inbox")
    }

    private func row(_ link: LinksServer.Link, in list: String) -> XCUIElement {
        app.collectionViews["links.\(list)"].buttons["link.\(link.id)"]
    }

    private func page(_ link: LinksServer.Link) -> XCUIElement {
        app.scrollViews["linkPage.\(link.id)"]
    }

    /// Where the links (all on .invalid hosts) open.
    private var safari: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.mobilesafari") }
    /// Generous: on a busy CI runner the app's own idle wait after the tap can take 10 seconds
    /// before Safari's launch even starts.
    private let safariLaunch: TimeInterval = 30

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

    /// Taps a text field and types once it has the keyboard focus. A slow CI Simulator can still
    /// be animating the field in (an alert, a sheet) when the tap lands, and typeText fails on a
    /// field without focus, so tap again until it takes.
    private func type(_ text: String, into field: XCUIElement) {
        for _ in 1...3 {
            field.tap()
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
            if XCTWaiter().wait(for: [focused], timeout: 5) == .completed { break }
        }
        field.typeText(text)
    }

    /// A change made on the server shows up at the app's next inbox poll, up to 8 seconds away, and
    /// on a slow CI Simulator a single accessibility query can take another 15.
    private func waitFor(_ element: XCUIElement, labelContaining text: String, timeout: TimeInterval = 30) {
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
