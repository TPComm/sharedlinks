import Foundation
import Testing
@testable import LinksKit

private func messageLink(_ id: Int, mine: Bool = false, watched: Bool = false) -> SharedLink {
    SharedLink(id: id, groupID: id % 2, url: URL(string: "https://example.com/raw/\(id)")!,
               platform: .web, title: "Link \(id)", addedBy: mine ? "me" : "friend",
               addedAt: Date(timeIntervalSince1970: Double(id)),
               seen: watched ? ["me": .now] : [:],
               shareURL: URL(string: "https://links.example.com/l/token-\(id)")!)
}

@Test func messagesSelectionAcceptsOnlySharePagesOnOurHost() {
    for scheme in ["http", "https"] {
        #expect(MessagesSelection.token(for: URL(string: "\(scheme)://links.example.com/l/token-1"),
                                        associatedDomain: "links.example.com") == "token-1")
    }
    for url in [nil, URL(string: "sharedlinks://l/token-1"), URL(string: "https://other.example/l/token-1"),
                URL(string: "https://links.example.com/invite/token-1"), URL(string: "https://links.example.com/l/"),
                URL(string: "https://links.example.com/l/token/extra"), URL(string: "https://links.example.com/l/bad%20token"),
                URL(string: "https://links.example.com:443/l/token-1"), URL(string: "https://user@links.example.com/l/token-1")] {
        #expect(MessagesSelection.token(for: url, associatedDomain: "links.example.com") == nil)
    }
    #expect(MessagesSelection.token(for: URL(string: "https://links.example.com/l/token-1"), associatedDomain: nil) == nil)
}

@Test func messagesInsertionRejectsStaleSessionConversationOrRow() throws {
    let row = MessagesPickerRow(link: messageLink(1))
    let user = LinkUser(id: "me", name: "Me")
    let insertion = try #require(MessagesInsertion(row: row, token: "token", currentUser: user))
    func loaded(_ links: [SharedLink]) -> MessagesPickerState {
        .loaded(MessagesPickerContent(state: InboxState(me: "me", users: [], links: links)))
    }
    let state = loaded([row.link])
    #expect(insertion.canInsert(token: "token", currentUser: user, conversationMatches: true, state: state))
    #expect(!insertion.canInsert(token: nil, currentUser: nil, conversationMatches: true, state: state))
    #expect(!insertion.canInsert(token: "new-token", currentUser: user, conversationMatches: true, state: state))
    #expect(!insertion.canInsert(token: "token", currentUser: LinkUser(id: "other", name: "Other"),
                                conversationMatches: true, state: state))
    #expect(!insertion.canInsert(token: "token", currentUser: user, conversationMatches: false, state: state))
    #expect(!insertion.canInsert(token: "token", currentUser: user, conversationMatches: true, state: loaded([])))
    #expect(!insertion.canInsert(token: "token", currentUser: user, conversationMatches: true, state: loaded([messageLink(2)])))
    var changed = row.link
    changed.shareURL = URL(string: "https://links.example.com/l/replacement")!
    #expect(!insertion.canInsert(token: "token", currentUser: user, conversationMatches: true, state: loaded([changed])))
    changed.shareURL = nil
    #expect(!insertion.canInsert(token: "token", currentUser: user, conversationMatches: true, state: loaded([changed])))
    for state in [MessagesPickerState.signedOut, .loading, .empty(), .error("Offline")] {
        #expect(!insertion.canInsert(token: "token", currentUser: user, conversationMatches: true, state: state))
    }
    #expect(MessagesInsertion(row: row, token: nil, currentUser: user) == nil)
    #expect(MessagesInsertion(row: row, token: "token", currentUser: nil) == nil)
    #expect(MessagesInsertion(row: MessagesPickerRow(link: changed), token: "token", currentUser: user) == nil)
}

@Test func messagesSectionsUseQueueAndRecentAcrossChats() {
    let queue = [messageLink(1), messageLink(2)]
    let recent = (3...30).map { messageLink($0, mine: $0 % 2 == 0, watched: true) }
    let inbox = InboxState(me: "me", users: [], links: queue + recent)
    let content = MessagesPickerContent(state: inbox)
    #expect(content.sections.map(\.title) == ["Queue", "Recent"])
    #expect(content.sections[0].rows.map(\.id) == inbox.links(for: .toWatch).map(\.id))
    #expect(content.sections[1].rows.map(\.id) == Array((11...30).reversed()))
    #expect(MessagesPickerContent(state: .empty).isEmpty)
}

@Test func messagesContentResolvesSendersFromItsInbox() {
    let friend = messageLink(1)
    let mine = messageLink(2, mine: true)
    let inbox = InboxState(me: "me", users: [LinkUser(id: "friend", name: "Friend")], links: [friend, mine])
    let rows = MessagesPickerContent(state: inbox).sections.flatMap(\.rows)
    #expect(rows.first { $0.id == friend.id }?.sender == "Friend")
    #expect(rows.first { $0.id == mine.id }?.sender == "You")
    let renamed = InboxState(me: "me", users: [LinkUser(id: "friend", name: "Renamed")], links: [friend])
    #expect(MessagesPickerContent(state: renamed).sections.first?.rows.first?.sender == "Renamed")
    #expect(MessagesPickerContent(state: InboxState(me: "me", users: [], links: [friend]))
        .sections.first?.rows.first?.sender == "Someone")
}

@Test func messagesPayloadUsesOnlyValidSharePage() {
    var link = messageLink(1)
    let payload = MessagesPayload(link: link)
    #expect(payload.caption == link.displayTitle)
    #expect(payload.subcaption == "Sent with Links")
    #expect(payload.url?.absoluteString == "https://links.example.com/l/token-1")
    #expect(payload.url != link.url)
    for url in [nil, URL(string: "sharedlinks://link/1"), URL(string: "https:/missing-host"),
                URL(string: "https://example.com/" + String(repeating: "a", count: 5000))] {
        link.shareURL = url
        let row = MessagesPickerRow(link: link)
        #expect(!row.canSend)
        #expect(row.payload.url == nil)
        #expect(row.guidance == "Open Links to refresh this link")
    }
    link.shareURL = URL(string: "http://example.com/" + String(repeating: "a", count: 4981))!
    #expect(link.shareURL?.absoluteString.count == 5000)
    #expect(MessagesPickerRow(link: link).canSend)
}

@MainActor private final class MessagesFixture {
    var token: String? = "test-token"
    var user: LinkUser? = LinkUser(id: "me", name: "Me")
    var snapshot: InboxState? = InboxState(me: "me", users: [], links: [messageLink(1)])
    var saved: InboxState?
    var sessionCleared = false
    var fetchCount = 0

    func picker(fetch: @escaping (String) async throws -> InboxState) -> MessagesPicker {
        MessagesPicker(token: { self.token }, currentUser: { self.user },
                       loadSnapshot: { self.snapshot }, saveSnapshot: { self.saved = $0 },
                       clearSnapshot: { self.snapshot = nil },
                       clearSession: { self.sessionCleared = true; self.token = nil },
                       fetch: { token in self.fetchCount += 1; return try await fetch(token) })
    }
}

@Test @MainActor func messagesShowsCacheBeforeRefreshAndSavesSuccess() async {
    let fixture = MessagesFixture()
    let fresh = InboxState(me: "me", users: [], links: [messageLink(2)])
    var picker: MessagesPicker!
    picker = fixture.picker { token in
        #expect(token == "test-token")
        guard case .loaded(let content, let notice) = picker.state else {
            Issue.record("Expected cached content before fetching"); return fresh
        }
        #expect(content.sections[0].rows.map(\.id) == [1])
        #expect(notice != nil)
        return fresh
    }
    await picker.refresh()
    #expect(fixture.saved == fresh)
    #expect(picker.state == .loaded(MessagesPickerContent(state: fresh)))
}

@Test @MainActor func messagesUnauthorizedClearsContentAndSnapshot() async {
    let fixture = MessagesFixture()
    let picker = fixture.picker { _ in throw APIError.signedOut }
    await picker.refresh()
    #expect(picker.state == .signedOut)
    #expect(fixture.snapshot == nil)
    #expect(fixture.sessionCleared)
    #expect(fixture.saved == nil)
}

@Test @MainActor func messagesRefreshErrorsKeepOnlyOwnCache() async {
    for failure in [APIError.offline, .server("Unavailable")] {
        for identity in ["me", "another", nil] as [String?] {
            let fixture = MessagesFixture()
            fixture.user = identity.map { LinkUser(id: $0, name: $0) }
            var picker: MessagesPicker!
            picker = fixture.picker { _ in
                if identity != "me" { #expect(picker.state == .loading) }
                throw failure
            }
            await picker.refresh()
            if identity == "me" {
                guard case .loaded(let content, let notice) = picker.state else {
                    Issue.record("Expected offline cache"); continue
                }
                #expect(content.sections[0].rows.map(\.id) == [1])
                #expect(notice != nil)
            } else {
                guard case .error = picker.state else { Issue.record("Expected error without own cache"); continue }
            }
            #expect(fixture.saved == nil)
            #expect(!fixture.sessionCleared)
        }
    }
}

@Test @MainActor func messagesNoTokenDoesNotFetchOrShowCache() async {
    let fixture = MessagesFixture()
    fixture.token = nil
    let picker = fixture.picker { _ in Issue.record("Unexpected fetch"); return .empty }
    await picker.refresh()
    #expect(picker.state == .signedOut)
    #expect(fixture.fetchCount == 0)
}

@Test @MainActor func messagesEmptyAndMissingCacheStates() async {
    let fixture = MessagesFixture()
    fixture.snapshot = nil
    let picker = fixture.picker { _ in .empty }
    await picker.refresh()
    #expect(picker.state == .empty())
    #expect(fixture.saved == .empty)
    let offline = fixture.picker { _ in throw APIError.offline }
    await offline.refresh()
    guard case .error = offline.state else { Issue.record("Expected error without cache"); return }
}
