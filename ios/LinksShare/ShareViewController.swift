import Intents
import LinkPresentation
import LinksKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WidgetKit

/// Entry point for "Links" in the share sheet (and for the Links conversation suggestion
/// in the share sheet's top row). Hosts the SwiftUI compose view.
final class ShareViewController: UIViewController {
    private lazy var model = ShareModel(context: extensionContext)

    override func viewDidLoad() {
        super.viewDidLoad()
        // Tells the app's tour that Links is reachable from the share sheet (#9).
        Onboarding.shared.recordShareExtensionOpened()
        let host = UIHostingController(rootView: ShareComposeView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor @Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading, ready, noLink, signedOut, sending, sent, duplicate(String), failed(String)
        /// Opened with the tour's practice link: say it worked, send nothing.
        case practice
    }

    private weak var context: NSExtensionContext?
    var phase: Phase = .loading
    var url: URL?
    var title: String?
    var image: UIImage?
    var note = ""
    var recipients: [String] = []

    init(context: NSExtensionContext?) {
        self.context = context
    }

    var platform: Platform { Platform(host: url?.host()) }

    func load() async {
        let snapshot = InboxSnapshot.load()
        recipients = (snapshot?.otherPeople ?? []).map(\.name)
        // Picked the "Links" conversation from the share sheet's suggestions row.
        if let intent = context?.intent as? INSendMessageIntent, recipients.isEmpty {
            recipients = intent.recipients?.compactMap(\.displayName) ?? []
        }
        url = await sharedURL()
        if Onboarding.isPractice(url) {
            phase = .practice
            return
        }
        guard SessionStore.isSignedIn else {
            phase = .signedOut
            return
        }
        guard let url else {
            phase = .noLink
            return
        }
        phase = .ready
        await loadPreview(for: url)
    }

    /// The first web link in what was shared: a URL attachment, or text that contains one.
    private func sharedURL() async -> URL? {
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = LinkText.webURL(fromSharedItem: try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)) {
                    return url
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = LinkText.firstURL(in: text) {
                    return url
                }
            }
            if let text = item.attributedContentText?.string, let url = LinkText.firstURL(in: text) {
                return url
            }
        }
        return nil
    }

    /// A quick preview with the system's LinkPresentation (the server fetches the real one later).
    private func loadPreview(for url: URL) async {
        let provider = LPMetadataProvider()
        provider.timeout = 5
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return }
        title = metadata.title
        if let imageProvider = metadata.imageProvider ?? metadata.iconProvider {
            image = await withCheckedContinuation { continuation in
                _ = imageProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }
    }

    func send() async {
        guard let url else { return }
        phase = .sending
        do {
            let result = try await APIClient().add(url.absoluteString, note: note)
            InboxSnapshot.update { state in
                if !state.links.contains(where: { $0.id == result.link.id }) { state.links.insert(result.link, at: 0) }
            }
            WidgetCenter.shared.reloadAllTimelines()
            if result.duplicate {
                let snapshot = InboxSnapshot.load()
                let who = snapshot.map { $0.isMine(result.link) ? "You" : $0.name(of: result.link.addedBy) } ?? "Someone"
                phase = .duplicate("\(who) already sent this \(LinkFormat.ago(result.link.addedAt).lowercased()).")
            } else {
                if let state = InboxSnapshot.load() { ShareSuggestions.donateSend(in: state) }
                phase = .sent
            }
            try? await Task.sleep(for: .seconds(1.1))
            context?.completeRequest(returningItems: nil)
        } catch APIError.signedOut {
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func finishPractice() {
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
