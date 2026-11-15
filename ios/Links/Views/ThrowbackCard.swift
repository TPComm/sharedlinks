import LinksKit
import SwiftUI
#if DEBUG
import CoreFoundation
#endif

struct ThrowbackCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var advances = 0
    let date: Date

    static var now: Date {
        #if DEBUG
        _ = configureTestClock
        if let testNow { return testNow }
        #endif
        return .now
    }

    #if DEBUG
    // Read, don't observe: advancing the test clock must still wait for the real TimelineView tick.
    private static var testNow: Date?
    private static let configureTestClock: Void = {
        let env = ProcessInfo.processInfo.environment
        guard env["LINKS_UI_TESTS"] == "1", let name = env["LINKS_THROWBACK_TEST_CLOCK"],
              let value = env["LINKS_THROWBACK_TEST_NOW"], let seconds = TimeInterval(value),
              seconds.isFinite else { return }
        testNow = Date(timeIntervalSince1970: seconds)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async {
                ThrowbackCard.testNow = ThrowbackCard.testNow?.addingTimeInterval(2)
            }
        }, name as CFString, nil, .deliverImmediately)
    }()
    #endif

    static var minimumAge: TimeInterval {
        let env = ProcessInfo.processInfo.environment
        if env["LINKS_UI_TESTS"] == "1", let value = env["LINKS_THROWBACK_MIN_AGE"],
           let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        return 7 * 24 * 60 * 60
    }

    var body: some View {
        card(on: date)
    }

    @ViewBuilder private func card(on date: Date) -> some View {
        let favorites = model.inbox.throwbacks(in: model.chat, now: date, minimumAge: Self.minimumAge)
        if !favorites.isEmpty {
            let start = InboxState.throwbackStartIndex(count: favorites.count, on: date)
            let link = favorites[(start + advances) % favorites.count]
            VStack(alignment: .leading, spacing: 16) {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        heading
                        originalDate(link.addedAt)
                    }
                } else {
                    HStack {
                        heading
                        Spacer()
                        originalDate(link.addedAt)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remember this one?")
                        .font(.title2.weight(.bold))
                    Text("An old favorite you reacted to together.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.showPage(link, on: .watched)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ThumbnailView(link: link)
                            .frame(width: 76, height: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(link.displayTitle)
                                .font(.headline)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if !link.note.isEmpty {
                                Text("“\(link.note)”")
                                    .font(.subheadline)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("From \(model.inbox.name(of: link.addedBy)) · \(link.sourceName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(link.displayTitle), from \(model.inbox.name(of: link.addedBy))")
                .accessibilityHint("Opens the original link page without changing seen status")
                .accessibilityIdentifier("throwback.open")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { reactionLabels(for: link) }
                    VStack(alignment: .leading, spacing: 6) { reactionLabels(for: link) }
                }
                if favorites.count > 1 {
                    Button {
                        advances = (advances + 1) % favorites.count
                    } label: {
                        Label("Another throwback", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("throwback.another")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(.orange.opacity(0.07).gradient)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.orange.opacity(0.2), lineWidth: 1)
            }
            .sensoryFeedback(.selection, trigger: advances)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("throwback.card")
            .padding(.vertical, 8)
        }
    }

    private var heading: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .accessibilityHidden(true)
            Text("THROWBACK")
                .tracking(1.5)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.orange)
    }

    private func originalDate(_ date: Date) -> some View {
        Text(date, format: .dateTime.month(.abbreviated).day().year())
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func reactionLabels(for link: SharedLink) -> some View {
        reaction(name: "You", emoji: link.reactions[model.inbox.me] ?? "")
        let friends = model.inbox.throwbackFriends(of: link)
        if let friend = friends.first {
            reaction(name: friend.name, emoji: link.reactions[friend.id] ?? "")
        }
        if friends.count > 1 {
            Text("+\(friends.count - 1) more")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reaction(name: String, emoji: String) -> some View {
        Text("\(emoji) \(name)")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.background.opacity(0.7), in: .capsule)
    }
}
