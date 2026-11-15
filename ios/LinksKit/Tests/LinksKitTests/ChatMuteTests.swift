import Foundation
import Testing
@testable import LinksKit

@Suite("Per-chat mute")
struct ChatMuteTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func missingAndNullFieldsSupportOlderServersAndCaches() throws {
        for json in [#"{"id":5}"#, #"{"id":5,"muted":null,"muted_until":null}"#] {
            let group = try Fixture.decode(LinkGroup.self, json)
            #expect(group.muted == nil && group.mutedUntil == nil)
            #expect(!group.isMuted(at: now))
        }
    }

    @Test func mutesExpireLocallyAndRoundTripThroughTheCache() throws {
        let group = try Fixture.decode(LinkGroup.self, #"{"id":5,"muted":true,"muted_until":1800000060}"#)
        #expect(group.isMuted(at: now))
        #expect(!group.isMuted(at: now.addingTimeInterval(60)))
        let cached = try APIClient.decoder.decode(LinkGroup.self, from: APIClient.encoder.encode(group))
        #expect(cached == group)
        #expect(LinkGroup(id: 5, muted: true).isMuted(at: now))
        #expect(!LinkGroup(id: 5, muted: false, mutedUntil: now.addingTimeInterval(60)).isMuted(at: now))
    }

    @Test func mutingDoesNotRemoveLinksFromTheBadgeOrLists() {
        var muted = chats
        muted.groups = muted.groups.map { group in
            var group = group
            group.muted = true
            return group
        }
        #expect(muted.toWatch == chats.toWatch)
        for filter in [InboxFilter.toWatch, .watched, .sent] {
            #expect(muted.links(for: filter) == chats.links(for: filter))
        }
    }

    @Test func durationsUseAnHourOrNineTomorrowAcrossDaylightSavings() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        for day in [7, 8] {
            let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 23, minute: 30)))
            #expect(ChatMuteDuration.hour.endDate(from: start) == start.addingTimeInterval(3600))
            let tomorrow = try #require(ChatMuteDuration.tomorrow.endDate(from: start, calendar: calendar))
            let parts = calendar.dateComponents([.day, .hour, .minute], from: tomorrow)
            #expect(parts.day == day + 1 && parts.hour == 9 && parts.minute == 0)
            #expect(tomorrow > start)
        }
        #expect(ChatMuteDuration.indefinite.endDate(from: now) == nil)
    }

    @Test func sendsOnlyMuteFieldsAndDecodesTheReturnedGroup() async throws {
        for (muted, until, json) in [
            (true, Optional<Date>.none, #"{"muted":true}"#),
            (true, Optional(now), #"{"muted":true,"muted_until":1800000000}"#),
            (false, Optional(now), #"{"muted":false}"#),
        ] {
            let server = StubServer(always: .json(#"{"group":{"id":5,"muted":true,"muted_until":1800000060}}"#))
            let group = try await server.client().setGroupMuted(5, muted: muted, until: until)
            #expect(group.muted == true && group.mutedUntil == now.addingTimeInterval(60))
            #expect(server.requests.only?.method == "PATCH")
            #expect(server.requests.only?.url.path() == "/api/groups/5")
            #expect(server.requests.only?.canonicalJSON == json)
        }
    }

    @Test func muteFailuresAreThrownRatherThanLookingSaved() async throws {
        let server = StubServer(always: .json(#"{"error":"Not a member."}"#, status: 403))
        await #expect(throws: APIError.self) {
            try await server.client().setGroupMuted(5, muted: true)
        }
    }

    @Test @MainActor func overlappingChoicesSaveAndApplyInTapOrderWithoutBlockingOtherChats() async throws {
        let queue = ChatMuteSaveQueue()
        let gate = MuteSaveGate()
        var applied = LinkGroup(id: 5, muted: true)
        var choices: [Bool] = []
        let unmute = queue.enqueue(5) {
            await gate.wait()
            choices.append(false)
            applied.muted = false
            return applied
        }
        await gate.entered()
        let muteAgain = queue.enqueue(5) {
            choices.append(true)
            applied.muted = true
            return applied
        }
        let other = queue.enqueue(6) { LinkGroup(id: 6, muted: true) }
        #expect(try await other.value.id == 6)
        #expect(choices.isEmpty, "A later save overtook the in-flight unmute")
        gate.open()
        #expect(try await unmute.value.muted == false)
        #expect(try await muteAgain.value.muted == true)
        #expect(choices == [false, true])
        #expect(applied.muted == true)
    }

    @Test @MainActor func aFailedSaveDoesNotPreventTheNextChoiceFromSaving() async throws {
        let queue = ChatMuteSaveQueue()
        let gate = MuteSaveGate()
        let failed = queue.enqueue(5) {
            await gate.wait()
            throw APIError.server("Offline")
        }
        await gate.entered()
        let next = queue.enqueue(5) { LinkGroup(id: 5, muted: true) }
        gate.open()
        await #expect(throws: APIError.self) { try await failed.value }
        #expect(try await next.value.muted == true)
        let later = queue.enqueue(5) { LinkGroup(id: 5, muted: false) }
        #expect(try await later.value.muted == false)
    }
}

/// Hold one request in flight without sleeps or a real network.
@MainActor
private final class MuteSaveGate {
    private var request: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { request = $0; observer?.resume(); observer = nil }
    }

    func entered() async {
        if request != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func open() { request?.resume(); request = nil }
}
