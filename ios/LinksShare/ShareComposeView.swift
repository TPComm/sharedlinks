import LinksKit
import SwiftUI

struct ShareComposeView: View {
    @Bindable var model: ShareModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Links")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if model.phase == .practice {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.finishPractice() }
                                .accessibilityIdentifier("share.practiceDone")
                        }
                    } else {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", role: .cancel) { model.cancel() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") { Task { await model.send() } }
                                .disabled(model.phase != .ready && !isFailed)
                        }
                    }
                }
        }
        .tint(Color.linksAccent) // extensions don't get the app's AccentColor asset
        .overlay { resultOverlay }
        .sensoryFeedback(.success, trigger: model.phase) { _, new in new == .sent || new == .practice }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .signedOut:
            ContentUnavailableView("Sign In to Links", systemImage: "person.crop.circle.badge.exclamationmark",
                                   description: Text("Open the Links app and sign in, then share again."))
        case .noLink:
            ContentUnavailableView("No Link Found", systemImage: "link",
                                   description: Text("There's no web link in what you shared."))
        case .practice:
            ContentUnavailableView {
                Label("You Found Links", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.linksAccent)
            } description: {
                Text("This is where reels and TikToks go to your friends: add a note if you like, then tap Send. This practice link stays here.")
            }
        default:
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        ThumbnailImage(platform: model.platform, image: model.image)
                            .frame(width: 60, height: 80)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.title ?? model.platform.noun)
                                .font(.headline)
                                .lineLimit(3)
                            Text(model.url?.host() ?? "")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    TextField("Add a note (optional)", text: $model.note, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($noteFocused)
                } footer: {
                    if !model.recipients.isEmpty {
                        Text("Goes to \(LinkFormat.names(model.recipients)).")
                    }
                }
                if case .failed(let message) = model.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(model.phase == .sending)
        }
    }

    @ViewBuilder private var resultOverlay: some View {
        switch model.phase {
        case .sending:
            ProgressView().controlSize(.large)
        case .sent:
            ResultBadge(symbol: "checkmark.circle.fill", title: "Sent", subtitle: nil)
        case .duplicate(let message):
            ResultBadge(symbol: "checkmark.circle", title: "Already in Links", subtitle: message)
        default:
            EmptyView()
        }
    }
}

private struct ResultBadge: View {
    let symbol: String
    let title: String
    let subtitle: String?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.linksAccent)
                .symbolEffect(.bounce, value: appeared)
            Text(title).font(.title3.bold())
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: 260)
        .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
        .transition(.scale.combined(with: .opacity))
        .onAppear { appeared = true }
    }
}
