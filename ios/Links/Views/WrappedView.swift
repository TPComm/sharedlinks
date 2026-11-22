import LinksKit
import SwiftUI

struct WrappedView: View {
    @Environment(AppModel.self) private var model
    @State private var period = Period.thisMonth
    @State private var wrapped: Wrapped?
    @State private var failure: String?

    enum Period: String, CaseIterable {
        case thisMonth = "This Month", lastMonth = "Last Month", thisYear = "This Year"
        var interval: DateInterval {
            let calendar = Calendar.current
            let date = self == .lastMonth ? calendar.date(byAdding: .month, value: -1, to: .now)! : .now
            return calendar.dateInterval(of: self == .thisYear ? .year : .month, for: date)!
        }
        func title(for date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = self == .thisYear ? "yyyy" : "MMMM yyyy"
            return formatter.string(from: date)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wrapped.period")
                if let wrapped {
                    let title = period.title(for: wrapped.start)
                    WrappedCard(wrapped: wrapped, title: title)
                        .accessibilityIdentifier("wrapped.card")
                    if let image = rendered(wrapped, title: title) {
                        ShareLink(item: image, preview: SharePreview("Links Wrapped · \(title)", image: image)) {
                            Label("Share Card", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wrapped.share")
                    }
                } else if let failure {
                    ContentUnavailableView("Couldn't load Wrapped", systemImage: "wifi.exclamationmark", description: Text(failure))
                    Button("Try Again") { Task { await load() } }
                } else { ProgressView("Gathering your highlights…") }
            }
            .padding()
        }
        .navigationTitle("Links Wrapped")
        .task(id: period) { await load() }
    }

    @MainActor private func load() async {
        wrapped = nil
        failure = nil
        let interval = period.interval
        do {
            let result = try await model.client.wrapped(start: interval.start, end: interval.end)
            try Task.checkCancellation()
            wrapped = result
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    @MainActor private func rendered(_ wrapped: Wrapped, title: String) -> Image? {
        let renderer = ImageRenderer(content: WrappedCard(wrapped: wrapped, title: title))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}

struct WrappedCard: View {
    let wrapped: Wrapped
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("LINKS WRAPPED", systemImage: "sparkles")
                .font(.headline)
            Text(title).font(.largeTitle.bold())
            if wrapped.received + wrapped.sent == 0 {
                Spacer()
                Text("Your next chapter starts with a link.").font(.title.bold())
                Text("Share something you love. Your highlights will appear here.")
                Spacer()
            } else {
                highlight("Your top sender", wrapped.topSender?.name ?? "Just you so far")
                    .accessibilityIdentifier("wrapped.topSender")
                HStack(alignment: .top, spacing: 24) {
                    highlight("Watch rate", wrapped.watchRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    highlight("Top platform", wrapped.topPlatform?.platform.capitalized ?? "—")
                }
                highlight("Most reacted", wrapped.mostReacted.map { $0.title ?? $0.url.host() ?? "A shared favorite" } ?? "The love is still loading")
                Spacer(minLength: 0)
                Text("\(wrapped.received) received · \(wrapped.sent) sent").font(.headline)
            }
            Text("Good links. Great company.").font(.subheadline)
        }
        .padding(30)
        .frame(width: 360, height: 640, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [.indigo, .purple, Color(red: 0.65, green: 0.15, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .environment(\.colorScheme, .light)
    }

    private func highlight(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.subheadline).opacity(0.8)
            Text(value).font(.title2.bold()).lineLimit(3)
        }
    }
}
