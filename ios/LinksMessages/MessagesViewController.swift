import LinksKit
import Messages
import SwiftUI
import UIKit

final class MessagesViewController: MSMessagesAppViewController {
    private let model = MessagesModel()
    private var refreshTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: MessagesPickerView(model: model,
            insert: { [weak self] row in self?.insert(row) },
            open: { [weak self] url in self?.extensionContext?.open(url) }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        updateSelectedMessage(conversation.selectedMessage)
        refreshTask?.cancel()
        refreshTask = Task { await model.picker.refresh() }
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        updateSelectedMessage(message)
    }

    override func willResignActive(with conversation: MSConversation) {
        super.willResignActive(with: conversation)
        updateSelectedMessage(nil)
    }

    private func updateSelectedMessage(_ message: MSMessage?) {
        model.selectedToken = MessagesSelection.token(for: message?.url)
    }

    private func insert(_ row: MessagesPickerRow) {
        guard let url = row.payload.url, let conversation = activeConversation, !model.inserting,
              let insertion = MessagesInsertion(row: row, token: SessionStore.token,
                                                currentUser: SessionStore.currentUser) else { return }
        model.inserting = true
        model.insertError = nil
        Task {
            defer { model.inserting = false }
            let data = ThumbnailStore.cached(row.link)
            let layout = MSMessageTemplateLayout()
            layout.image = data.flatMap(UIImage.init(data:))
            layout.caption = row.payload.caption
            layout.subcaption = row.payload.subcaption
            let message = MSMessage(session: MSSession())
            message.layout = layout
            message.url = url
            guard insertion.canInsert(token: SessionStore.token, currentUser: SessionStore.currentUser,
                                      conversationMatches: activeConversation === conversation,
                                      state: model.picker.state) else { return }
            do {
                try await conversation.insert(message)
                requestPresentationStyle(.compact)
            } catch {
                model.insertError = error.localizedDescription
            }
        }
    }
}

@MainActor @Observable final class MessagesModel {
    let picker = MessagesPicker()
    var selectedToken: String?
    var inserting = false
    var insertError: String?
}

private struct MessagesPickerView: View {
    let model: MessagesModel
    let insert: (MessagesPickerRow) -> Void
    let open: (URL) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let token = model.selectedToken {
                    Button("Open in Links", systemImage: "arrow.up.forward.app") { open(DeepLink.link(token: token).url) }
                }
                if let error = model.insertError { Text(error).foregroundStyle(.red) }
                switch model.picker.state {
                case .signedOut:
                    Text("Open Links to sign in")
                    Button("Open Links") { open(DeepLink.inbox.url) }
                case .loading:
                    ProgressView("Loading Links…")
                case .empty(let notice):
                    noticeView(notice)
                    ContentUnavailableView("No links yet", systemImage: "link", description: Text("Your Queue and recent links will appear here."))
                    retry
                case .error(let notice):
                    Text(notice)
                    retry
                case .loaded(let content, let notice):
                    noticeView(notice)
                    ForEach(content.sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                Button { insert(row) } label: {
                                    HStack(spacing: 12) {
                                        MessagesThumbnail(link: row.link)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.link.displayTitle).font(.headline).lineLimit(2)
                                            Text("From \(row.sender) · \(LinkFormat.ago(row.link.addedAt))")
                                                .font(.caption).foregroundStyle(.secondary)
                                            if let guidance = row.guidance { Text(guidance).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                                .disabled(!row.canSend || model.inserting)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Links")
            .overlay { if model.inserting { ProgressView("Preparing draft…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        }
    }

    @ViewBuilder private func noticeView(_ notice: String?) -> some View {
        if let notice {
            VStack(alignment: .leading) { Text(notice).font(.callout); retry }
        }
    }

    private var retry: some View {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.picker.refresh() } }
    }
}

private struct MessagesThumbnail: View {
    let link: SharedLink
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { ZStack { Color.secondary.opacity(0.12); Text(link.platform.glyph) } }
        }
        .frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 8))
        .task(id: link) {
            image = ThumbnailStore.cached(link).flatMap(UIImage.init(data:))
            if image == nil {
                image = await ThumbnailStore.shared.data(for: link, client: APIClient()).flatMap(UIImage.init(data:))
            }
        }
    }
}
