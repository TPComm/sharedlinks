import Foundation
import Testing
@testable import LinksKit

private let recapDate = Date(timeIntervalSince1970: 1_794_700_000)
private var recapCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func recapLink(_ id: Int, sender: String = "a", offset: Double = 0,
                       reactions: [String: String] = [:], receipts: [String: Double] = [:]) -> SharedLink {
    let date = recapDate.addingTimeInterval(offset)
    return SharedLink(id: id, groupID: 1, url: URL(string: "https://example.com/\(id)")!,
                      platform: .web, addedBy: sender, addedAt: date,
                      seen: receipts.mapValues { date.addingTimeInterval($0) }, reactions: reactions)
}

private func recapState(_ links: [SharedLink]) -> InboxState {
    InboxState(me: "a", users: ["a", "b", "c"].map { LinkUser(id: $0, name: $0) },
               groups: [LinkGroup(id: 1, members: ["a", "b", "c"])], links: links)
}

@Test func monthlyRecapPopulatedAndDeterministicTies() {
    let state = recapState([
        recapLink(1, reactions: ["b": "❤️", "c": "❤️"]),
        recapLink(2, sender: "b", offset: 1, reactions: ["a": "🔥", "c": "😂"]),
        recapLink(3, sender: "b", offset: 1, reactions: ["a": "🔥", "c": "😂"]),
        recapLink(4, offset: 2)
    ])
    let recap = state.monthlyRecap(in: 1, monthContaining: recapDate, calendar: recapCalendar)
    #expect(recap.linkCount == 4)
    #expect(recap.sharerCount == 2)
    #expect(recap.mostLoved?.link.id == 3)
    #expect(recap.mostLoved?.emojiCounts == ["🔥": 1, "😂": 1])
    #expect(recap.topSharer?.member == "a")
    #expect(recap.topSharer?.count == 2)
    #expect(recap.fastestWatcher == nil)
}

@Test func monthlyRecapEmptyAndMonthBoundaries() {
    let month = recapCalendar.dateInterval(of: .month, for: recapDate)!
    var links = [recapLink(1), recapLink(2), recapLink(3), recapLink(4)]
    links[0].addedAt = month.start
    links[1].addedAt = month.start.addingTimeInterval(-1)
    links[2].addedAt = month.end.addingTimeInterval(-1)
    links[3].addedAt = month.end
    let state = recapState(links)
    #expect(state.monthlyRecap(in: 1, monthContaining: recapDate, calendar: recapCalendar).linkCount == 2)
    let empty = state.monthlyRecap(in: 99, monthContaining: recapDate, calendar: recapCalendar)
    #expect(empty.linkCount == 0 && empty.sharerCount == 0)
    #expect(empty.mostLoved == nil && empty.topSharer == nil && empty.fastestWatcher == nil)
    let next = recapCalendar.date(byAdding: .month, value: 2, to: recapDate)!
    #expect(state.monthlyRecap(in: 1, monthContaining: next, calendar: recapCalendar).linkCount == 0)
}

@Test func monthlyRecapMedianExcludesSendersNegativeAndSingleReceipts() {
    let state = recapState([
        recapLink(1, receipts: ["a": 0, "b": 60, "c": 10]),
        recapLink(2, receipts: ["a": 0, "b": 120, "c": -10]),
        recapLink(3, receipts: ["b": 10_000]),
        recapLink(4, sender: "b", receipts: ["b": 0])
    ])
    let recap = state.monthlyRecap(in: 1, monthContaining: recapDate, calendar: recapCalendar)
    #expect(recap.fastestWatcher?.member == "b")
    #expect(recap.fastestWatcher?.medianInterval == 120)
    #expect(recap.fastestWatcher?.receiptCount == 3)
    let even = recapState(Array(state.links.prefix(2))).monthlyRecap(in: 1, monthContaining: recapDate, calendar: recapCalendar)
    #expect(even.fastestWatcher?.medianInterval == 90)
}

@Test func monthlyRecapDoesNotNameUnknownDeletedFormerOrBlockedMembers() {
    var state = recapState([recapLink(1, sender: "unknown", reactions: ["unknown": "❤️"], receipts: ["b": 1]),
                            recapLink(2, sender: "deleted", receipts: ["b": 1])])
    state.groups[0].members += ["unknown", "deleted"]
    state.blocked = ["b"]
    let recap = state.monthlyRecap(in: 1, monthContaining: recapDate, calendar: recapCalendar)
    #expect(recap.linkCount == 2)
    #expect(recap.topSharer == nil && recap.fastestWatcher == nil)
    #expect(recap.mostLoved?.emojiCounts == ["❤️": 1])
    state.groups[0].members = ["b"]
    #expect(state.monthlyRecap(in: 1, monthContaining: recapDate).linkCount == 0)
}

@Test func monthlyRecapRespectsLocalCalendarAcrossDSTAndYearBoundary() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15))!
    let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
    let end = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
    var links = [recapLink(1), recapLink(2), recapLink(3)]
    links[0].addedAt = start.addingTimeInterval(-1)
    links[1].addedAt = start
    links[2].addedAt = end
    let recap = recapState(links).monthlyRecap(in: 1, monthContaining: date, calendar: calendar)
    #expect(recap.month.start == start && recap.month.end == end)
    #expect(recap.linkCount == 1)
    let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 15))!
    let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
    #expect(recapState([]).monthlyRecap(in: 1, monthContaining: december, calendar: calendar).month.end == january)
}

@Test func monthlyRecapWatcherTiesAreStableAndOtherChatsAreExcluded() {
    var other = recapLink(3, sender: "b", reactions: ["a": "🔥", "b": "🔥"])
    other.groupID = 2
    let recap = recapState([recapLink(1, receipts: ["b": 60, "c": 60]),
                            recapLink(2, receipts: ["b": 60, "c": 60]), other])
        .monthlyRecap(in: 1, monthContaining: recapDate, calendar: recapCalendar)
    #expect(recap.linkCount == 2)
    #expect(recap.mostLoved == nil)
    #expect(recap.fastestWatcher?.member == "b")
}
