import LinksKit
import SwiftUI

/// Pick for Me: for when To Watch is long and nothing in it calls out. Spins through the unwatched
/// links like a slot machine and lands on one (the longer a link has waited, the likelier), then
/// opens it, marking it watched, or spins again.
struct PickForMeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card in the window: each one the reel passes, then the pick.
    @State private var showing: SharedLink?
    /// Set once the reel stops.
    @State private var pick: SharedLink?
    @State private var ticks = 0
    @State private var landings = 0
    @State private var spin: Task<Void, Never>?
    @State private var prefetched = false

    /// What the To Watch list shows, in the chat it shows.
    private var pool: [SharedLink] { model.inbox.links(for: .toWatch, in: model.chat) }

    var body: some View {
        VStack(spacing: 22) {
            Text(pick == nil ? "Shuffling your To Watch…" : "Here's your pick")
                .font(.title2.weight(.bold))
                .contentTransition(.opacity)
                .padding(.top, 28)

            ZStack {
                if let showing {
                    PickCard(link: showing)
                        .id(showing.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top)))
                }
            }
            .frame(width: PickCard.size.width, height: PickCard.size.height)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .scaleEffect(pick == nil ? 0.94 : 1)
            .shadow(color: .black.opacity(pick == nil ? 0.08 : 0.22), radius: pick == nil ? 8 : 22, y: 8)
            .overlay { Confetti(trigger: landings) }
            .accessibilityIdentifier("pickForMe.card")

            if let pick {
                landed(pick).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.22), Color(uiColor: .systemBackground)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .padding(16)
                .accessibilityIdentifier("pickForMe.close")
        }
        .sensoryFeedback(.selection, trigger: ticks)
        .sensoryFeedback(.success, trigger: landings)
        .task { startSpin() }
        .onDisappear { spin?.cancel() }
    }

    private func landed(_ link: SharedLink) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(waiting(link))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !link.note.isEmpty {
                    Text("“\(link.note)”")
                        .font(.subheadline.italic())
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.center)

            Button {
                watch(link)
            } label: {
                Label(link.platform.openTitle, systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("pickForMe.watch")

            if pool.count > 1 {
                Button("Spin Again", systemImage: "dice") { startSpin() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("pickForMe.again")
            }
        }
        .frame(maxWidth: 360)
    }

    /// "Sam sent this yesterday.", "Sam's been waiting 4 days for you to see this."
    private func waiting(_ link: SharedLink) -> String {
        let name = model.inbox.name(of: link.addedBy)
        switch Int(Date.now.timeIntervalSince(link.addedAt) / 86400) {
        case ..<1: return "\(name) sent this today."
        case 1: return "\(name) sent this yesterday."
        case let days: return "\(name)'s been waiting \(days) days for you to see this."
        }
    }

    /// Opens it as its page's Watch button does, with the page underneath to react on afterwards.
    private func watch(_ link: SharedLink) {
        model.showPage(link, on: .toWatch)
        model.open(link, with: openURL)
        dismiss()
    }

    private func startSpin() {
        spin?.cancel()
        let pool = pool
        guard let winner = Self.pick(from: pool, other: pick?.id) else { return dismiss() }
        withAnimation(.snappy) { pick = nil }
        spin = Task {
            if !prefetched {
                // So the reel shows pictures, not placeholders, as it flies past.
                let client = model.client
                await withTaskGroup(of: Void.self) { group in
                    for link in pool where link.thumb != nil {
                        group.addTask { _ = await ThumbnailCache.image(for: link, client: client) }
                    }
                }
                prefetched = true
            }
            let reel = reduceMotion ? [winner] : Self.reel(pool, endingAt: winner)
            for (i, link) in reel.enumerated() {
                // Eases out: 60ms a card at first, about half a second for the last.
                let t = reel.count > 1 ? Double(i) / Double(reel.count - 1) : 1
                let gap = 0.06 + 0.44 * t * t * t
                try? await Task.sleep(for: .seconds(gap))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: min(gap * 0.9, 0.3))) { showing = link }
                ticks += 1
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { pick = winner }
            landings += 1
            AccessibilityNotification.Announcement("Picked \(winner.displayTitle)").post()
        }
    }

    /// One link, weighted by days waiting (a link sent today has weight 1, a week old 8), and not
    /// `other` (the last pick) when there's anything else.
    static func pick(from pool: [SharedLink], other: Int?, now: Date = .now) -> SharedLink? {
        let choices = pool.count > 1 ? pool.filter { $0.id != other } : pool
        let weights = choices.map { 1 + max(0, now.timeIntervalSince($0.addedAt)) / 86400 }
        var roll = Double.random(in: 0..<max(weights.reduce(0, +), .leastNonzeroMagnitude))
        for (link, weight) in zip(choices, weights) {
            roll -= weight
            if roll < 0 { return link }
        }
        return choices.last
    }

    /// The cards the reel passes: random, never the same twice in a row, ending on `winner`.
    static func reel(_ pool: [SharedLink], endingAt winner: SharedLink, length: Int = 18) -> [SharedLink] {
        guard pool.count > 1 else { return [winner] }
        var reel: [SharedLink] = []
        while reel.count < length - 1 {
            guard let next = pool.filter({ $0.id != reel.last?.id }).randomElement() else { break }
            reel.append(next)
        }
        if reel.last?.id == winner.id { reel.removeLast() }
        return reel + [winner]
    }
}

/// A link on the reel: a fixed size, so the window doesn't change shape as cards go by.
private struct PickCard: View {
    @Environment(AppModel.self) private var model
    let link: SharedLink

    static let size = CGSize(width: 300, height: 380)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThumbnailView(link: link, cornerRadius: 0)
                .frame(height: 270)
            VStack(alignment: .leading, spacing: 8) {
                Text(link.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    AvatarView(user: model.inbox.user(link.addedBy), size: 22)
                    Text("\(model.inbox.name(of: link.addedBy)) · \(LinkFormat.ago(link.addedAt))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .combine)
    }
}

/// A burst of popcorn and sparkles from the card when the reel lands.
private struct Confetti: View {
    let trigger: Int
    @State private var pieces: [Piece] = []

    struct Piece: Identifiable {
        let id = UUID()
        let symbol: String
        let angle: Double
        let distance: CGFloat
        let spin: Double
    }

    var body: some View {
        ZStack {
            ForEach(pieces) { PieceView(piece: $0) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            pieces = (0..<26).map { _ in
                Piece(symbol: ["🍿", "✨", "🎉", "⭐️", "🎬"].randomElement() ?? "✨",
                      angle: .random(in: 0..<(2 * .pi)), distance: .random(in: 140...280),
                      spin: .random(in: -220...220))
            }
        }
    }

    private struct PieceView: View {
        let piece: Piece
        @State private var out = false

        var body: some View {
            Text(piece.symbol)
                .font(.title)
                .scaleEffect(out ? 1 : 0.3)
                .rotationEffect(.degrees(out ? piece.spin : 0))
                .offset(x: out ? cos(piece.angle) * piece.distance : 0,
                        y: out ? sin(piece.angle) * piece.distance : 0)
                .animation(.easeOut(duration: 1.1), value: out)
                .opacity(out ? 0 : 1)
                .animation(.easeIn(duration: 0.5).delay(0.7), value: out)
                .onAppear { out = true }
        }
    }
}
