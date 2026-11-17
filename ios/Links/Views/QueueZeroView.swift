import SwiftUI

struct QueueZeroView: View {
    let recap: String
    let celebrate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.mint.opacity(0.12))
                    .frame(width: 132, height: 132)
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.mint)
                    .offset(x: 57, y: -45)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.mint)
                    .symbolEffect(.bounce, value: appeared && celebrate && !reduceMotion)
            }
            .scaleEffect(appeared || !celebrate || reduceMotion ? 1 : 0.85)

            VStack(spacing: 10) {
                Text("Queue Zero")
                    .font(.largeTitle.bold())
                Text("All seen. A little room to breathe.")
                    .font(.headline)
                Text(recap)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: 440)
        .accessibilityIdentifier("queueZero")
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.25)) {
                appeared = true
            }
        }
    }
}
