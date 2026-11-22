import XCTest

@MainActor
final class MessagesUITests: XCTestCase {
    private var server: LinksServer!
    private let app = XCUIApplication()
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() async throws {
        continueAfterFailure = false
        server = try LinksServer.fromEnvironment()
    }

    override func tearDown() async throws {
        await MainActor.run {
            attachMessagesHost()
            messages.terminate()
        }
        try await super.tearDown()
    }

    private func attachMessagesHost() {
        let screenshot = XCTAttachment(screenshot: messages.screenshot())
        screenshot.name = "Messages host"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: messages.debugDescription)
        hierarchy.name = "Messages accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    func testQueueLinkInsertsADraftWithoutSending() throws {
        let host = "messages-\(UUID().uuidString.prefix(8).lowercased()).invalid"
        let link = try server.add("https://\(host)/watch", as: server.friend)
        XCTAssertNotNil(link.token, "the seeded link has no public share page")
        let server = server!
        addTeardownBlock { try? server.delete(link.id, as: server.friend) }
        launchLinks()
        try openLinksInMessages()

        XCTAssert(messages.staticTexts["Queue"].waitForExistence(timeout: 30), "no Queue in Messages")
        let row = messages.buttons.containing(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
        XCTAssert(row.waitForExistence(timeout: 20), "the friend's link is missing")
        row.tap()

        let draft = messages.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Sent with Links")).firstMatch
        XCTAssert(draft.waitForExistence(timeout: 30), "inserting the link didn't create a Messages draft")
        let transcript = messages.collectionViews["TranscriptCollectionView"]
        XCTAssert(transcript.exists, "can't verify that nothing was sent without the transcript")
        XCTAssertFalse(transcript.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", host)).firstMatch.exists,
                       "the link was sent instead of inserted")
        let attachment = XCTAttachment(screenshot: messages.screenshot())
        attachment.name = "Inserted draft, not sent"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDailyRollupInsertsADraftWithoutSending() throws {
        let name = "Rollup-\(UUID().uuidString.prefix(8))"
        let chat = try server.startChat(name: name, as: server.me)
        let server = server!
        addTeardownBlock { try? server.leaveChat(chat.id, as: server.me) }
        let link = try server.add("https://rollup-\(UUID().uuidString.prefix(8).lowercased()).invalid/article", to: chat.id, as: server.me)
        XCTAssertNotNil(link.token)
        launchLinks()
        try openLinksInMessages()

        let row = messages.buttons.containing(NSPredicate(format: "label CONTAINS %@", "1 link to \(name)")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 30), "today's roll-up is missing")
        row.tap()
        let draft = messages.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "1 link from today")).firstMatch
        XCTAssert(draft.waitForExistence(timeout: 30), "the roll-up didn't create a draft")
        let transcript = messages.collectionViews["TranscriptCollectionView"]
        XCTAssert(transcript.exists, "can't verify that nothing was sent without the transcript")
        let sent = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "links from today", "link from today")
        XCTAssertFalse(transcript.descendants(matching: .any).matching(sent).firstMatch.exists,
                       "the roll-up was sent instead of inserted")
        let attachment = XCTAttachment(screenshot: messages.screenshot())
        attachment.name = "Inserted daily roll-up, not sent"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchLinks() {
        app.launchEnvironment = ["LINKS_SERVER_URL": server.url.absoluteString,
                                 "LINKS_DEV_TOKEN": server.me, "LINKS_UI_TESTS": "1"]
        app.launch()
        XCTAssert(app.tabBars.buttons["Queue"].waitForExistence(timeout: 30), "Links didn't sign in")
    }

    private func openLinksInMessages() throws {
        messages.launch()
        let continueButton = messages.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 5) { continueButton.tap() }
        let cancel = messages.navigationBars["CKComposeChat"].buttons["Cancel"]
        if cancel.exists && cancel.isHittable { cancel.tap() }
        let transcript = messages.collectionViews["TranscriptCollectionView"]
        if transcript.waitForExistence(timeout: 2) {
            let back = messages.navigationBars.buttons.element(boundBy: 0)
            guard back.waitForExistence(timeout: 5), back.isHittable else {
                attachMessagesHost()
                XCTFail("Messages couldn't return from the open conversation to its conversation list")
                return
            }
            back.tap()
        }
        let seeded = messages.cells.containing(NSPredicate(format: "label CONTAINS %@", "564-8583")).firstMatch
        guard seeded.waitForExistence(timeout: 20) else {
            attachMessagesHost()
            XCTFail("Messages is missing the seeded iMessage conversation +1 (555) 564-8583")
            return
        }
        seeded.tap()
        if continueButton.waitForExistence(timeout: 2) { continueButton.tap() }
        let add = messages.buttons["add"]
        guard add.waitForExistence(timeout: 10), add.isEnabled else {
            attachMessagesHost()
            XCTFail("Messages app drawer is missing or disabled in the seeded iMessage conversation")
            return
        }
        add.tap()
        messages.swipeUp()
        let links = messages.cells.matching(NSPredicate(format: "label == 'Links'")).firstMatch
        XCTAssert(links.waitForExistence(timeout: 20), "Links isn't in the Messages app drawer")
        links.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
