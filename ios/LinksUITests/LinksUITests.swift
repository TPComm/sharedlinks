import CoreFoundation
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

    func testSeenStartsWithTheLinkWhenNoThrowbackIsEligible() throws {
        let meID = try server.state(as: server.me).me
        let name = "Throwback \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        deleteAfterwards(link.id)
        try server.setSeen(link.id, true, as: server.me)

        launch(environment: ["LINKS_THROWBACK_MIN_AGE": "0"])
        pickChat(name)
        app.tabBars.buttons["Seen"].tap()
        waitForRow(link, in: "watched")
        XCTAssertFalse(app.otherElements["throwback.card"].exists)
        let firstRow = app.collectionViews["links.watched"].cells.firstMatch
        XCTAssert(firstRow.buttons["link.\(link.id)"].exists, "an empty row precedes the seen link")
    }

    func testThrowbackAppearsWhenTheFirstFavoriteBecomesOldEnough() throws {
        let meID = try server.state(as: server.me).me
        let name = "Throwback \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        deleteAfterwards(link.id)
        try server.setSeen(link.id, true, as: server.me)
        try server.react(link.id, emoji: "❤️", as: server.me)
        try server.react(link.id, emoji: "❤️", as: server.friend)

        let clockName = "com.tpcomm.links.throwback.\(UUID().uuidString)"
        launch(environment: ["LINKS_THROWBACK_MIN_AGE": "1", "LINKS_THROWBACK_TEST_CLOCK": clockName,
                             "LINKS_THROWBACK_TEST_NOW": String(link.addedAt)])
        pickChat(name)
        app.tabBars.buttons["Seen"].tap()
        waitForRow(link, in: "watched")
        let card = app.otherElements["throwback.card"]
        XCTAssertFalse(card.exists, "the link should initially be too recent")

        // Setup can take arbitrarily long: only advance time once the initial state is on screen.
        // The clock isn't observed by SwiftUI, so the real minute timeline must discover eligibility.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(rawValue: clockName as CFString), nil, nil, true)
        XCTAssert(card.waitForExistence(timeout: 125), "the first Throwback never appeared as it aged")
        XCTAssert(card.buttons["throwback.open"].label.contains("Friend"))
    }

    func testThrowbackOpensThePageWithoutChangingSeenStatus() throws {
        let meID = try server.state(as: server.me).me
        let name = "Throwback \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        deleteAfterwards(link.id)
        try server.setSeen(link.id, true, as: server.me)
        try server.react(link.id, emoji: "❤️", as: server.me)
        try server.react(link.id, emoji: "❤️", as: server.friend)

        launch(environment: ["LINKS_THROWBACK_MIN_AGE": "0"])
        pickChat(name)
        app.tabBars.buttons["Seen"].tap()
        waitForRow(link, in: "watched")
        let card = app.otherElements["throwback.card"]
        XCTAssert(card.waitForExistence(timeout: 5))
        let heading = card.staticTexts["THROWBACK"]
        XCTAssert(heading.exists, "the Throwback heading is missing")
        XCTAssertGreaterThan(heading.frame.width, 40, "the Throwback heading has no visible width")
        XCTAssertFalse(app.buttons["throwback.another"].exists)
        app.buttons["throwback.open"].tap()
        XCTAssert(page(link).waitForExistence(timeout: 5))
        let state = try server.state(as: server.me)
        XCTAssertNotNil(state.link(link.id)?.seen[meID], "opening the throwback changed seen status")
    }

    func testSignedInLaunchShowsTheInbox() throws {
        launch()
        XCTAssert(app.navigationBars["Queue"].exists)
        for tab in ["Queue", "Seen", "Sent", "Search"] {
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
        XCTAssert(row.label.contains("Unseen"), row.label)
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
        app.tabBars.buttons["Seen"].tap()
        XCTAssert(self.row(link, in: "watched").waitForExistence(timeout: 5), "not in Watched")
    }

    func testMarkingWatchedMovesItToWatchedAndTellsTheServer() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        row.swipeRight()
        app.collectionViews["links.toWatch"].buttons["Seen"].tap()
        XCTAssert(row.waitForNonExistence(timeout: 5), "still in To Watch")

        app.tabBars.buttons["Seen"].tap()
        let watched = self.row(link, in: "watched")
        XCTAssert(watched.waitForExistence(timeout: 5))
        XCTAssertFalse(watched.label.contains("Unseen"), watched.label)

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
        XCTAssert(app.tabBars.buttons["Queue"].isSelected)
        // It stays in the app, and doesn't count as watched.
        XCTAssertEqual(app.state, .runningForeground)
        let me = try server.state(as: server.me).me
        XCTAssertNil(try server.state(as: server.friend).link(link.id)?.seen[me], "the widget marked it watched")
    }

    func testSharedLinkPageOpensTheLinksPage() throws {
        let link = try seed(by: server.friend)
        let token = try XCTUnwrap(link.token, "the server gave the link no share token")
        launch()
        waitForRow(link, in: "toWatch")
        app.tabBars.buttons["Sent"].tap()
        // What a /l/ universal link hands the app; the Simulator can't open universal links.
        app.open(URL(string: "sharedlinks://l/\(token)")!)
        XCTAssert(page(link).waitForExistence(timeout: 10), "no page for the shared link")
        XCTAssert(app.tabBars.buttons["Queue"].isSelected)
        XCTAssertEqual(app.state, .runningForeground)
        let me = try server.state(as: server.me).me
        XCTAssertNil(try server.state(as: server.friend).link(link.id)?.seen[me], "the shared link marked it watched")
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
        XCTAssertEqual(app.buttons["linkPage.markWatched"].label, "Mark as Seen")
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

    /// The issue this page exists for (#7): watch it, come back, and you're on its page to react,
    /// instead of on a list it has already left. Opening it marked it watched (#76).
    func testComingBackFromWatchingLandsOnTheLinksPage() throws {
        let link = try seed(by: server.friend)
        launch()
        waitForRow(link, in: "toWatch").tap()
        XCTAssert(page(link).waitForExistence(timeout: 5), "no page for the link")

        let me = try server.state(as: server.me).me
        app.buttons["linkPage.watch"].tap()
        try server.eventually(timeout: 20, "seen by me") { try server.state(as: server.friend).link(link.id)?.seen[me] }
        XCTAssert(safari.wait(for: .runningForeground, timeout: safariLaunch), "the link didn't open")
        app.activate()
        XCTAssert(page(link).waitForExistence(timeout: 10), "not on the link's page")
        XCTAssert(app.buttons["linkPage.markNotWatched"].waitForExistence(timeout: 5), "not shown as watched")
        XCTAssertFalse(app.buttons["linkPage.markWatched"].exists, "still offers Mark as Watched")
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

    // MARK: Comments

    func testCommentThreadCRUDAndUnreadState() throws {
        let note = "Sender note stays separate \(shortID())"
        let link = try seed(by: server.friend, note: note)
        let friendComment = try server.addComment(link.id, body: "That ending!", as: server.friend)
        let me = try server.state(as: server.me).me
        XCTAssertNil(try server.state(as: server.me).link(link.id)?.seen[me])
        launch()
        let row = waitForRow(link, in: "toWatch")
        waitFor(row, labelContaining: "1 comment · New")
        row.tap()
        let page = page(link)
        XCTAssert(page.waitForExistence(timeout: 5))
        for _ in 0..<3 where !app.staticTexts["That ending!"].isHittable { page.swipeUp() }
        XCTAssert(app.staticTexts["That ending!"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["comment.edit.\(friendComment.id)"].exists)
        XCTAssertFalse(app.buttons["comment.delete.\(friendComment.id)"].exists)

        let field = app.textFields["comments.draft"]
        XCTAssert(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["comments.send"].isEnabled)
        type("   ", into: field)
        XCTAssertFalse(app.buttons["comments.send"].isEnabled, "whitespace must not send")
        type("I watched it twice", into: field)
        app.buttons["comments.send"].tap()
        let posted = try server.eventually("new comment") {
            try server.comments(link.id, as: server.friend).first { $0.body == "I watched it twice" }
        }
        let seenAt = try XCTUnwrap(server.state(as: server.me).link(link.id)?.seen[me])
        let edit = app.buttons["comment.edit.\(posted.id)"]
        for _ in 0..<4 where !edit.isHittable { page.swipeUp() }
        XCTAssert(edit.waitForExistence(timeout: 10))
        edit.tap()
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "I watched it twice".count))
        type("Even better the second time", into: field)
        app.buttons["comments.send"].tap()
        try server.eventually("edited comment") {
            try server.comments(link.id, as: server.friend).first {
                $0.id == posted.id && $0.body == "Even better the second time" && $0.editedAt != nil
            }
        }
        XCTAssertEqual(try server.state(as: server.me).link(link.id)?.note, note)
        let delete = app.buttons["comment.delete.\(posted.id)"]
        for _ in 0..<3 where !delete.isHittable { page.swipeUp() }
        delete.tap()
        app.buttons["Delete Comment"].tap()
        try server.eventually("comment deleted") {
            try server.comments(link.id, as: server.friend).count == 1 ? true : nil
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Commenting marks the link seen; editing or deleting the comment doesn't undo it.
        XCTAssertEqual(try server.state(as: server.me).link(link.id)?.seen[me], seenAt)
        XCTAssert(row.waitForNonExistence(timeout: 10), "commented link stayed in Queue")
        app.tabBars.buttons["Seen"].tap()
        let seenRow = waitForRow(link, in: "watched")
        waitFor(seenRow, labelContaining: "1 comment")
        XCTAssertFalse(seenRow.label.contains("· New"), seenRow.label)
        app.terminate()
        launch()
        app.tabBars.buttons["Seen"].tap()
        let readRow = waitForRow(link, in: "watched")
        XCTAssertFalse(readRow.label.contains("· New"), "read state lost after relaunch")

        try server.addComment(link.id, body: "Did you spot the cat?", as: server.friend)
        app.collectionViews["links.watched"].swipeDown()
        waitFor(readRow, labelContaining: "2 comments · New")
    }

    func testCommentThreadRefreshesEditsWithoutActivityChanges() throws {
        let link = try seed(by: server.friend)
        let first = try server.addComment(link.id, body: "Original earlier comment", as: server.friend)
        let prefix = String(repeating: "Same prefix ", count: 10)
        let latest = try server.addComment(link.id, body: prefix + "original ending", as: server.friend)
        let before = try XCTUnwrap(server.state(as: server.me).link(link.id))
        launch()
        waitForRow(link, in: "toWatch").tap()
        let page = page(link)
        XCTAssert(page.waitForExistence(timeout: 5))
        for _ in 0..<3 where !app.staticTexts[first.body].isHittable { page.swipeUp() }
        XCTAssert(app.staticTexts[first.body].waitForExistence(timeout: 10))

        try server.editComment(first.id, body: "Updated earlier comment", as: server.friend)
        XCTAssert(app.staticTexts["Updated earlier comment"].waitForExistence(timeout: 30))
        try server.editComment(latest.id, body: prefix + "revised ending", as: server.friend)
        let edited = app.staticTexts.matching(NSPredicate(format: "label == %@", prefix + "revised ending")).firstMatch
        XCTAssert(edited.waitForExistence(timeout: 30))
        let after = try XCTUnwrap(server.state(as: server.me).link(link.id))
        XCTAssertEqual(after.commentCount, before.commentCount)
        XCTAssertEqual(after.lastComment, before.lastComment)
    }

    func testCommentThreadRefreshesAfterForegrounding() throws {
        let link = try seed(by: server.friend)
        launch()
        waitForRow(link, in: "toWatch").tap()
        let page = page(link)
        XCTAssert(page.waitForExistence(timeout: 5))
        for _ in 0..<3 where !app.staticTexts["comments.empty"].isHittable { page.swipeUp() }
        XCTAssert(app.staticTexts["comments.empty"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        try server.addComment(link.id, body: "A fresh reply", as: server.friend)
        app.activate()
        XCTAssert(app.staticTexts["A fresh reply"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["comments.empty"].exists)
    }

    func testReportingACommentHidesOnlyThatComment() throws {
        let link = try seed(by: server.friend, note: "Keep this link")
        let comment = try server.addComment(link.id, body: "A reportable comment", as: server.friend)
        launch()
        waitForRow(link, in: "toWatch").tap()
        let page = page(link)
        XCTAssert(page.waitForExistence(timeout: 5))
        let report = app.buttons["comment.report.\(comment.id)"]
        for _ in 0..<4 where !report.isHittable { page.swipeUp() }
        XCTAssert(report.waitForExistence(timeout: 10))
        report.tap()
        app.buttons["Harassment or Bullying"].tap()
        XCTAssert(app.staticTexts["comments.empty"].waitForExistence(timeout: 10))
        XCTAssertEqual(try server.comments(link.id, as: server.me).count, 0)
        XCTAssertEqual(try server.comments(link.id, as: server.friend).count, 1)
        XCTAssertNotNil(try server.state(as: server.me).link(link.id))
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
        app.buttons["blockedPeople"].tap()
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
        XCTAssert(app.staticTexts["Starts a chat with just you two."].waitForExistence(timeout: 5), "All Chats invites someone into a chat with just me")
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

    func testCancellingAnInviteThatsAlreadyGoneSaysSoAndDropsIt() throws {
        let id = try server.invite(email: "gone@example.com", as: server.me)
        launch()
        app.buttons["account"].tap()
        app.buttons["People"].tap()
        let pending = app.staticTexts["gone@example.com"]
        XCTAssert(pending.waitForExistence(timeout: 5), "not under Invited")
        // Cancelled on another phone (or used) while this one still lists it.
        try server.cancelInvite(id, as: server.me)
        pending.swipeLeft()
        app.buttons["Cancel Invite"].tap()

        let alert = app.alerts["Couldn't Do That"]
        XCTAssert(alert.waitForExistence(timeout: 10), "no alert")
        XCTAssert(alert.staticTexts["That invite was already used or cancelled."].exists)
        alert.buttons["OK"].tap()
        XCTAssert(alert.waitForNonExistence(timeout: 5))
        XCTAssert(app.buttons["inviteFriend"].exists, "People closed")
        XCTAssert(pending.waitForNonExistence(timeout: 5), "put back under Invited")
        app.buttons["Done"].tap()
    }

    func testReactingFromTheFeed() throws {
        let link = try seed(by: server.friend)
        launch()
        let row = waitForRow(link, in: "toWatch")
        let me = try server.state(as: server.me).me

        let react = app.buttons["react.\(link.id)"]
        XCTAssertEqual(react.label, "React")
        // A generous target (TestFlight feedback: "the reaction trigger is quite small"): it runs
        // to the row's trailing edge and takes a tap well away from the smiley itself.
        XCTAssertGreaterThanOrEqual(react.frame.width, 48)
        XCTAssertGreaterThanOrEqual(react.frame.height, 48)
        XCTAssertEqual(react.frame.maxX, row.frame.maxX, accuracy: 1)
        react.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
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

    func testCustomReactionFromTheFeedShowsOnThePageAndInSent() throws {
        let link = try seed(by: server.friend)
        let emoji = "👩🏽‍💻"
        let me = try server.state(as: server.me).me
        launch()
        let row = waitForRow(link, in: "toWatch")
        app.buttons["react.\(link.id)"].tap()
        let choose = app.buttons["reaction.custom"]
        XCTAssert(choose.waitForExistence(timeout: 5))
        choose.tap()

        let field = app.textFields["reaction.emoji"]
        let confirm = app.buttons["reaction.confirm"]
        XCTAssert(field.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        field.typeText(emoji)
        XCTAssert(confirm.isEnabled)
        confirm.tap()

        waitFor(row, labelContaining: "\(emoji) You")
        try server.eventually("custom reaction saved") {
            try server.state(as: server.friend).link(link.id)?.reactions[me] == emoji ? true : nil
        }
        row.tap()
        XCTAssert(page(link).waitForExistence(timeout: 5))
        let remove = app.buttons["reaction.currentCustom"]
        XCTAssert(remove.exists)
        XCTAssertEqual(remove.label, "Remove your reaction, \(emoji)")

        app.terminate()
        launch(as: server.friend)
        app.tabBars.buttons["Sent"].tap()
        let sent = waitForRow(link, in: "sent")
        waitFor(sent, labelContaining: "\(emoji) ")
        sent.tap()
        XCTAssert(page(link).staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "\(emoji) "))
            .firstMatch.waitForExistence(timeout: 5))
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

    func testTheProfileShowsWhoIsSignedIn() throws {
        launch()
        app.buttons["account"].tap()
        let email = app.staticTexts["profile.email"]
        XCTAssert(email.waitForExistence(timeout: 5), "no email on the profile")
        XCTAssertEqual(email.label, "me@e2e.test")
        XCTAssertFalse(app.staticTexts["profile.name"].label.isEmpty, "no name on the profile")
        XCTAssert(app.buttons["people"].exists, "no People on the profile")
        app.buttons["Done"].tap()
        XCTAssert(email.waitForNonExistence(timeout: 5), "Done didn't close the profile")
    }

    /// The photo picker runs out of process, so the photo goes up through the API; this checks the
    /// profile shows it and can take it away again.
    func testRemovingTheProfilePhotoGoesBackToInitials() throws {
        let api = server!
        try api.setPhoto(as: api.me)
        addTeardownBlock { try? api.removePhoto(as: api.me) }
        launch()
        app.buttons["account"].tap()
        let photo = app.buttons["profile.photo"]
        XCTAssert(photo.waitForExistence(timeout: 5), "no photo row on the profile")
        XCTAssertEqual(photo.label, "Change Profile Photo")
        photo.tap()
        let remove = app.buttons["Remove Photo"]
        XCTAssert(remove.waitForExistence(timeout: 5), "no Remove Photo in the photo menu")
        remove.tap()
        try api.eventually("the photo removed") { try api.avatar(as: api.me) == nil ? true : nil }
        XCTAssert(app.buttons["Add Profile Photo"].waitForExistence(timeout: 10), "the profile still offers to change the photo")
    }

    func testNotificationTogglesSaveEachSetting() throws {
        let api = server!
        guard try api.notifications(as: api.me) != nil else {
            return XCTFail("this server has no notification settings (GET /api/me has no notifications)")
        }
        try api.setNotifications(watched: true, reactions: true, as: api.me)
        addTeardownBlock { try? api.setNotifications(watched: true, reactions: true, as: api.me) }
        launch()
        app.buttons["account"].tap()
        let watched = scrolledTo(app.switches["notify.watched"])
        let reactions = app.switches["notify.reactions"]
        XCTAssert(watched.waitForExistence(timeout: 10), "no watched toggle on the profile")
        XCTAssertEqual(watched.value as? String, "1")
        XCTAssertEqual(reactions.value as? String, "1")

        watched.switches.firstMatch.tap()
        waitFor(watched, value: "0")
        try api.eventually("watched pushes off") {
            try api.notifications(as: api.me) == .init(watched: false, reactions: true) ? true : nil
        }
        reactions.switches.firstMatch.tap()
        waitFor(reactions, value: "0")
        try api.eventually("reaction pushes off") {
            try api.notifications(as: api.me) == .init(watched: false, reactions: false) ? true : nil
        }
        watched.switches.firstMatch.tap()
        waitFor(watched, value: "1")
        try api.eventually("watched pushes back on") {
            try api.notifications(as: api.me) == .init(watched: true, reactions: false) ? true : nil
        }
    }

    func testSigningOutReturnsToSignIn() throws {
        launch(as: server.spare)
        app.buttons["account"].tap()
        XCTAssert(app.staticTexts["profile.email"].waitForExistence(timeout: 5), "the profile didn't open")
        // The Help rows start below the fold, and a List only makes the rows on screen.
        XCTAssert(scrolledTo(app.descendants(matching: .any)["Privacy Policy"]).exists,
                  "no Privacy Policy in the profile")
        scrolledTo(app.buttons["About Links"]).tap()
        let about = app.alerts.firstMatch
        XCTAssert(about.waitForExistence(timeout: 5), "About Links didn't open")
        XCTAssert(about.label.hasPrefix("Links "), "the About title has no version: \(about.label)")
        let fullNotice = about.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                                  "Facebook is a trademark of Meta Platforms, Inc."))
        XCTAssert(fullNotice.firstMatch.exists, "About Links doesn't list every platform's owner")
        about.buttons["OK"].tap()
        XCTAssert(about.waitForNonExistence(timeout: 5))
        let signOut = scrolledTo(app.buttons["Sign Out"])
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
        scrolledTo(app.buttons["Delete Account…"]).tap()
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

    // MARK: Chats

    func testChatTasteMatchCountsAllAndOpensTheLatestThreeLinkPages() throws {
        let meID = try server.state(as: server.me).me
        let name = "Taste \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        var matches: [LinksServer.Link] = []
        for _ in 0..<4 {
            let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
            try server.react(link.id, emoji: "❤️", as: server.me)
            try server.react(link.id, emoji: "🔥", as: server.friend)
            matches.append(link)
        }
        let oneSided = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        try server.react(oneSided.id, emoji: "❤️", as: server.me)
        launch()
        pickChat(name)
        openChatPicker()
        app.buttons["Chat Info"].tap()
        let summary = app.staticTexts["tasteMatch.summary"]
        XCTAssert(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "You and Friend both loved 4 links")
        XCTAssertFalse(app.buttons["tasteMatch.link.\(matches[0].id)"].exists)
        XCTAssertFalse(app.buttons["tasteMatch.link.\(oneSided.id)"].exists)
        for link in matches.suffix(3).reversed() {
            scrolledTo(app.buttons["tasteMatch.link.\(link.id)"]).tap()
            XCTAssert(app.scrollViews["linkPage.\(link.id)"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            openChatPicker()
            app.buttons["Chat Info"].tap()
        }
        let state = try server.state(as: server.me)
        XCTAssert(matches.allSatisfy { state.link($0.id)?.seen[meID] == nil }, "browsing matches marked links seen")
    }

    func testChatTasteMatchShowsAnEmptyStateForOneSidedLoves() throws {
        let meID = try server.state(as: server.me).me
        let name = "New taste \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        try server.react(link.id, emoji: "❤️", as: server.me)
        launch()
        pickChat(name)
        openChatPicker()
        app.buttons["Chat Info"].tap()
        XCTAssert(app.staticTexts["tasteMatch.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["tasteMatch.summary"].exists)
        XCTAssertFalse(app.buttons["tasteMatch.link.\(link.id)"].exists)
    }

    func testChatTasteMatchOpensFromTheChatsList() throws {
        let meID = try server.state(as: server.me).me
        let name = "List taste \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        try server.react(link.id, emoji: "❤️", as: server.me)
        try server.react(link.id, emoji: "🔥", as: server.friend)
        launch()
        openChatPicker()
        app.buttons["Chats…"].tap()
        scrolledTo(app.buttons["chat.row.\(chat.id)"]).tap()
        scrolledTo(app.buttons["tasteMatch.link.\(link.id)"]).tap()
        XCTAssert(app.scrollViews["linkPage.\(link.id)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Chat Info"].exists)
        XCTAssertNil(try server.state(as: server.me).link(link.id)?.seen[meID])
    }

    func testChatTasteMatchNeedsTheWholeGroupAndRefreshesReactionChanges() throws {
        let meID = try server.state(as: server.me).me
        let thirdID = try server.state(as: server.deletable).me
        let name = "Group taste \(shortID())"
        let chat = try server.startChat(name: name, members: [meID, thirdID], as: server.friend)
        leaveAfterwards(chat.id)
        let server = server!
        addTeardownBlock { try? server.leaveChat(chat.id, as: server.deletable) }
        let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        try server.react(link.id, emoji: "❤️", as: server.me)
        try server.react(link.id, emoji: "🔥", as: server.friend)
        launch()
        pickChat(name)
        openChatPicker()
        app.buttons["Chat Info"].tap()
        XCTAssert(app.staticTexts["tasteMatch.empty"].waitForExistence(timeout: 5))

        try server.react(link.id, emoji: "😂", as: server.deletable)
        app.swipeDown()
        let summary = app.staticTexts["tasteMatch.summary"]
        XCTAssert(summary.waitForExistence(timeout: 15))
        XCTAssertEqual(summary.label, "All 3 of you loved 1 link")
        try server.react(link.id, emoji: "👎", as: server.deletable)
        app.swipeDown()
        XCTAssert(app.staticTexts["tasteMatch.empty"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["tasteMatch.link.\(link.id)"].exists)
    }

    func testChatTasteMatchAtLargestTextSizeOpensTheLinkPage() throws {
        let meID = try server.state(as: server.me).me
        let name = "Large taste \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        try server.react(link.id, emoji: "❤️", as: server.me)
        try server.react(link.id, emoji: "🔥", as: server.friend)
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        defer { app.launchArguments = [] }
        launch()
        pickChat(name)
        openChatPicker()
        let info = app.buttons["Chat Info"]
        for _ in 0..<5 where !info.isHittable { app.swipeUp() }
        info.tap()
        let summary = app.staticTexts["tasteMatch.summary"]
        XCTAssert(summary.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(summary.frame.width, 0)
        scrolledTo(app.buttons["tasteMatch.link.\(link.id)"]).tap()
        XCTAssert(app.scrollViews["linkPage.\(link.id)"].waitForExistence(timeout: 5))
    }

    func testChatInfoSavesMuteDurationsAndKeepsLinksVisible() throws {
        let meID = try server.state(as: server.me).me
        let name = "Mute \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let link = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        deleteAfterwards(link.id)
        launch()
        pickChat(name)
        openChatPicker()
        app.buttons["Chat Info"].tap()
        let toggle = scrolledTo(app.switches["chat.mute"])
        XCTAssert(toggle.waitForExistence(timeout: 5))

        toggle.switches.firstMatch.tap()
        // Popover-style confirmation dialogs dismiss by tapping outside instead of a Cancel row.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.navigationBars["Chat Info"].tap() }
        waitFor(toggle, value: "0")
        XCTAssertEqual(try server.state(as: server.me).group(chat.id)?.muted, false)

        let start = Date().timeIntervalSince1970
        toggle.switches.firstMatch.tap()
        app.buttons["For 1 Hour"].tap()
        waitFor(toggle, value: "1")
        let hour = try server.eventually("chat muted for an hour") {
            let group = try server.state(as: server.me).group(chat.id)
            return group?.muted == true ? group?.mutedUntil : nil
        }
        XCTAssertEqual(hour, start + 3600, accuracy: 60)
        XCTAssertEqual(try server.state(as: server.friend).group(chat.id)?.muted, false)

        app.buttons["Change Duration…"].tap()
        app.buttons["Until Tomorrow"].tap()
        let tomorrow = try server.eventually("chat muted until tomorrow") {
            let until = try server.state(as: server.me).group(chat.id)?.mutedUntil
            return until != hour ? until : nil
        }
        let expected = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
            of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)!
        XCTAssertEqual(tomorrow, expected.timeIntervalSince1970, accuracy: 1)

        app.buttons["Change Duration…"].tap()
        app.buttons["Until I Turn It Back On"].tap()
        try server.eventually("chat muted indefinitely") {
            let group = try server.state(as: server.me).group(chat.id)
            return group?.muted == true && group?.mutedUntil == nil ? true : nil
        }
        app.buttons["Done"].tap()
        waitForRow(link, in: "toWatch")
        app.terminate()
        launch()
        pickChat(name)
        openChatPicker()
        app.buttons["Chat Info"].tap()
        XCTAssert(toggle.waitForExistence(timeout: 5))
        waitFor(toggle, value: "1")
        toggle.switches.firstMatch.tap()
        waitFor(toggle, value: "0")
        try server.eventually("chat unmuted") {
            try server.state(as: server.me).group(chat.id)?.muted == false ? true : nil
        }
    }

    func testChatListSwipeMutesAndUnmutesOneChat() throws {
        let meID = try server.state(as: server.me).me
        let chat = try server.startChat(name: "Swipe \(shortID())", members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        launch()
        openChatPicker()
        app.buttons["Chats…"].tap()
        let row = app.buttons["chat.row.\(chat.id)"]
        XCTAssert(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["Mute"].tap()
        app.buttons["Until I Turn It Back On"].tap()
        let indicator = app.images["chat.muted.\(chat.id)"]
        XCTAssert(indicator.waitForExistence(timeout: 10))
        try server.eventually("swipe muted the chat") {
            try server.state(as: server.me).group(chat.id)?.muted == true ? true : nil
        }
        row.swipeLeft()
        app.buttons["Unmute"].tap()
        XCTAssert(indicator.waitForNonExistence(timeout: 10))
        try server.eventually("swipe unmuted the chat") {
            try server.state(as: server.me).group(chat.id)?.muted == false ? true : nil
        }
    }

    func testStartingAChatAndSendingALinkToIt() throws {
        let friendID = try server.state(as: server.friend).me
        launch()
        let name = "Film club \(shortID())"
        openChatPicker()
        app.buttons["New Chat…"].tap()
        let field = app.textFields["chat.name"]
        XCTAssert(field.waitForExistence(timeout: 5), "no New Chat sheet")
        type(name, into: field)
        app.buttons["chat.person.Friend"].tap()
        app.buttons["chat.save"].tap()
        XCTAssert(field.waitForNonExistence(timeout: 10), "the New Chat sheet stayed open")

        let chat = try server.eventually("the new chat") {
            try server.state(as: server.me).groups.first { $0.name == name }
        }
        leaveAfterwards(chat.id)
        XCTAssertFalse(chat.isDefault)
        XCTAssertEqual(Set(chat.members), Set([try server.state(as: server.me).me, friendID]))
        // The lists now show the new chat.
        XCTAssert(app.buttons["chatPicker"].label.contains(name), app.buttons["chatPicker"].label)

        // A new link goes to the chat the lists show.
        let url = uniqueURL()
        app.buttons["newLink"].tap()
        let text = app.textFields["addLink.text"]
        XCTAssert(text.waitForExistence(timeout: 5))
        XCTAssert(app.buttons["addLink.chat"].label.contains(name), app.buttons["addLink.chat"].label)
        type(url, into: text)
        app.buttons["addLink.send"].tap()
        XCTAssert(text.waitForNonExistence(timeout: 10), "the New Link sheet stayed open")
        let link = try server.eventually("the new link") {
            try server.state(as: server.friend).links.first { $0.url == url }
        }
        deleteAfterwards(link.id)
        XCTAssertEqual(link.groupID, chat.id)
    }

    func testTheChatPickerFiltersEveryList() throws {
        let meID = try server.state(as: server.me).me
        let name = "Picker \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let inChat = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        let everyone = try seed(by: server.friend)
        deleteAfterwards(inChat.id)

        launch()
        XCTAssert(app.buttons["chatPicker"].label.contains("All Chats"), app.buttons["chatPicker"].label)
        waitForRow(inChat, in: "toWatch")
        XCTAssert(row(everyone, in: "toWatch").exists)

        pickChat(name)
        XCTAssert(row(everyone, in: "toWatch").waitForNonExistence(timeout: 5), "a link from another chat still shows")
        XCTAssert(row(inChat, in: "toWatch").exists)

        // An invite from here is into this chat.
        app.buttons["account"].tap()
        app.buttons["People"].tap()
        app.buttons["inviteFriend"].tap()
        XCTAssert(app.staticTexts["They’ll join \(name)."].waitForExistence(timeout: 5), "the invite isn't into the picked chat")
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()

        // Every tab shows the same chat.
        app.tabBars.buttons["Search"].tap()
        XCTAssert(row(inChat, in: "all").waitForExistence(timeout: 5))
        XCTAssertFalse(row(everyone, in: "all").exists)

        pickChat("All Chats")
        XCTAssert(row(everyone, in: "all").waitForExistence(timeout: 5))
    }

    func testInviteLinkWhileSignedInOpensItsChat() throws {
        let name = "Invited \(shortID())"
        let chat = try server.startChat(name: name, as: server.friend)
        leaveAfterwards(chat.id)
        let inChat = try server.add(uniqueURL(), to: chat.id, as: server.friend)
        deleteAfterwards(inChat.id)
        let invite = try server.invite(to: chat.id, as: server.friend)

        launch()
        app.open(URL(string: "sharedlinks://invite/\(invite)")!)
        XCTAssert(row(inChat, in: "toWatch").waitForExistence(timeout: 15), "the chat's link isn't in To Watch")
        XCTAssert(app.buttons["chatPicker"].label.contains(name), app.buttons["chatPicker"].label)
        let me = try server.state(as: server.me).me
        XCTAssert(try server.state(as: server.friend).group(chat.id)?.members.contains(me) == true, "not in the chat")
    }

    func testRenamingAddingPeopleToAndLeavingAChat() throws {
        let friendID = try server.state(as: server.friend).me
        let chat = try server.startChat(as: server.me)
        leaveAfterwards(chat.id)
        let mine = try server.add(uniqueURL(), to: chat.id, as: server.me)
        deleteAfterwards(mine.id)

        launch()
        pickChat("Just You")
        let name = "Renamed \(shortID())"
        openChatPicker()
        app.buttons["Rename…"].tap()
        let field = app.textFields["chat.name"]
        XCTAssert(field.waitForExistence(timeout: 5), "no Rename sheet")
        type(name, into: field)
        app.buttons["chat.save"].tap()
        XCTAssert(field.waitForNonExistence(timeout: 10), "the Rename sheet stayed open")
        try server.eventually("the new name") { try server.state(as: server.me).group(chat.id)?.name == name ? true : nil }

        openChatPicker()
        app.buttons["Add People…"].tap()
        let friend = app.buttons["chat.person.Friend"]
        XCTAssert(friend.waitForExistence(timeout: 5), "no Add People sheet")
        friend.tap()
        app.buttons["chat.save"].tap()
        XCTAssert(friend.waitForNonExistence(timeout: 10), "the Add People sheet stayed open")
        // Friend now sees the chat, and the link sent before they joined.
        let theirs = try server.eventually("Friend in the chat") {
            try server.state(as: server.friend).group(chat.id)
        }
        XCTAssert(theirs.members.contains(friendID))
        XCTAssertNotNil(try server.state(as: server.friend).link(mine.id))

        openChatPicker()
        app.buttons["Leave Chat"].tap()
        let confirm = app.sheets.buttons["Leave Chat"].exists ? app.sheets.buttons["Leave Chat"] : app.buttons["Leave Chat"].firstMatch
        XCTAssert(confirm.waitForExistence(timeout: 5), "no confirmation")
        confirm.tap()
        try server.eventually("left the chat") { try server.state(as: server.me).group(chat.id) == nil ? true : nil }
        XCTAssert(app.buttons["chatPicker"].label.contains("All Chats"), app.buttons["chatPicker"].label)
        // The link I sent stays in the chat for Friend.
        XCTAssertNotNil(try server.state(as: server.friend).link(mine.id))
    }

    /// The Share Extension's "To:" row. Its Send can't reach this test server (the extension
    /// doesn't get the app's LINKS_SERVER_URL), so APIClientTests cover the `group_id` it sends.
    func testTheShareSheetsToRowPicksAChat() throws {
        let meID = try server.state(as: server.me).me
        let name = "Shared \(shortID())"
        let chat = try server.startChat(name: name, members: [meID], as: server.friend)
        leaveAfterwards(chat.id)
        let everyone = try seed(by: server.friend)

        launch()
        waitForRow(everyone, in: "toWatch").tap()
        XCTAssert(page(everyone).waitForExistence(timeout: 5), "no page for the link")
        app.navigationBars.buttons["Share…"].firstMatch.tap()
        let sheet = app.collectionViews["activityCollectionView"]
        XCTAssert(sheet.waitForExistence(timeout: 30), "no share sheet")
        if !sheet.cells["Links"].waitForExistence(timeout: 10) {
            sheet.cells["More"].tap()
        }
        app.cells["Links"].firstMatch.tap()

        // It starts on Everyone, and says who the picked chat's link goes to.
        let to = app.buttons["share.chat"]
        XCTAssert(to.waitForExistence(timeout: 30), "no To row in the Share Extension")
        XCTAssert(to.label.contains("Everyone"), to.label)
        to.tap()
        let pick = app.buttons[name].firstMatch
        XCTAssert(pick.waitForExistence(timeout: 30), "no \(name) in the chat picker")
        pick.tap()
        XCTAssert(to.label.contains(name), to.label)
        XCTAssert(app.staticTexts["Goes to Friend."].waitForExistence(timeout: 5), "the footer doesn't follow the chat")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssert(to.waitForNonExistence(timeout: 10), "the Share Extension stayed open")
    }

    // MARK: Helpers

    private func openChatPicker() {
        let picker = app.buttons["chatPicker"]
        XCTAssert(picker.waitForExistence(timeout: 10), "no chat picker")
        picker.tap()
    }

    /// Picks a chat in the picker on the tab showing, waiting for one the server just made.
    private func pickChat(_ title: String) {
        for attempt in 1...3 {
            openChatPicker()
            let item = app.buttons[title].firstMatch
            if item.waitForExistence(timeout: 5) {
                item.tap()
                break
            }
            // Not in the inbox yet: close the menu and pull to refresh, as a person would.
            app.tap()
            if attempt < 3 { app.collectionViews.firstMatch.swipeDown() }
        }
        XCTAssert(app.buttons["chatPicker"].label.contains(title), "picked \(title), shows \(app.buttons["chatPicker"].label)")
    }

    /// Me and Friend both leave, which deletes the chat and its links.
    private func leaveAfterwards(_ id: Int) {
        let server = server!
        addTeardownBlock {
            try? server.leaveChat(id, as: server.me)
            try? server.leaveChat(id, as: server.friend)
        }
    }

    /// Launches signed in (DEBUG builds take a session token from LINKS_DEV_TOKEN), on the inbox.
    private func launch(as token: String? = nil, environment: [String: String] = [:]) {
        app.launchEnvironment = [
            "LINKS_SERVER_URL": server.url.absoluteString,
            "LINKS_DEV_TOKEN": token ?? server.me,
            // No notification prompt (AppModel.requestNotificationPermission), and no pages restored
            // from an earlier test (RootView.restoreNavigation).
            "LINKS_UI_TESTS": "1",
        ]
        app.launchEnvironment.merge(environment) { _, value in value }
        app.launch()
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 20), "no inbox")
    }

    /// The profile's list makes rows only as they scroll in, so the bottom ones need a swipe.
    @discardableResult
    private func scrolledTo(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<5 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element
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

    /// A change made on the server shows up at the app's next inbox poll, up to 8 seconds away, and
    /// on a slow CI Simulator a single accessibility query can take another 15.
    private func waitFor(_ element: XCUIElement, labelContaining text: String, timeout: TimeInterval = 30) {
        let label = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        wait(for: [label], timeout: timeout)
    }

    private func waitFor(_ toggle: XCUIElement, value: String, timeout: TimeInterval = 30) {
        let flipped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        wait(for: [flipped], timeout: timeout)
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

extension XCTestCase {
    /// Taps a text field and types once it has the keyboard focus. A slow CI Simulator can still
    /// be animating the field in (an alert, a sheet) when the tap lands, and typeText fails on a
    /// field without focus, so tap again until it takes.
    func type(_ text: String, into field: XCUIElement) {
        for _ in 1...3 {
            field.tap()
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
            if XCTWaiter().wait(for: [focused], timeout: 5) == .completed { break }
        }
        field.typeText(text)
    }
}
