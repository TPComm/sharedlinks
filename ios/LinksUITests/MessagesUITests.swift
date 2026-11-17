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
        let compose = messages.buttons["Compose"]
        if compose.waitForExistence(timeout: 20) {
            compose.tap()
            let recipient = messages.textFields.firstMatch
            XCTAssert(recipient.waitForExistence(timeout: 10), "no recipient field")
            recipient.tap()
            recipient.typeText("+15550130199\n")
        } else {
            messages.open(URL(string: "sms:+15550130199")!)
        }
        let body = messages.textFields["messageBodyField"]
        if body.waitForExistence(timeout: 10) { body.tap() }
        let add = messages.buttons.matching(NSPredicate(format: "label == 'Apps' OR label == 'add'")).firstMatch
        let drawerExists = add.waitForExistence(timeout: 10)
        #if targetEnvironment(simulator)
        let recipient = messages.textFields["To:"]
        let recipientSearching = NSPredicate(format: "value CONTAINS[c] 'Searching'")
        if drawerExists && !add.isEnabled {
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)], timeout: 20)
        } else if !drawerExists && recipient.exists && recipientSearching.evaluate(with: recipient) {
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS[c] 'Searching')"), object: recipient)], timeout: 20)
        }
        if (add.exists && !add.isEnabled) || (!add.exists && recipient.exists && recipientSearching.evaluate(with: recipient)) {
            attachMessagesHost()
            throw XCTSkip("Messages on this Simulator can't open iMessage apps: the app drawer is disabled (no iMessage daemon); run on a device")
        }
        #endif
        XCTAssert(add.exists, "no Messages app drawer button")
        XCTAssert(add.isEnabled, "Messages disabled its app drawer for this recipient")
        add.tap()
        let links = messages.buttons["Links"]
        for _ in 0..<4 where !links.isHittable {
            let more = messages.buttons["More"]
            if more.exists && more.isHittable { more.tap() }
            else { messages.swipeUp() }
        }
        XCTAssert(links.waitForExistence(timeout: 20), "Links isn't in the Messages app drawer")
        links.tap()
    }
}
