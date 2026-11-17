import Intents
import LinksKit
import UserNotifications

/// Dresses up new-link pushes (#27) before iOS shows them: the sender's photo, as Messages shows
/// it (a communication notification), and the link's thumbnail as an attachment. The server
/// sends `mutable-content` and what to fetch; the thumbnail comes from our server with the
/// session in the App Group keychain. Anything that fails or runs out of time leaves the push as
/// the server wrote it.
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: Delivery?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let note = LinkNotification(userInfo: request.content.userInfo),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else { return contentHandler(request.content) }
        let delivery = Delivery(content: content, note: note, handler: contentHandler)
        self.delivery = delivery
        work = Task {
            async let thumb = Self.thumbnail(note)
            async let avatar = Self.avatar(note)
            delivery.deliver(Media(thumb: await thumb, avatar: await avatar))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        delivery?.deliver(nil)
    }

    /// The thumbnail, saved where `UNNotificationAttachment` can take it from.
    static func thumbnail(_ note: LinkNotification) async -> URL? {
        guard let path = note.thumb, SessionStore.token != nil,
              let (data, type) = try? await APIClient().thumbnail(path: path),
              let ext = LinkNotification.fileExtension(forContentType: type) else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        return (try? data.write(to: file)) == nil ? nil : file
    }

    /// The sender's photo (WorkOS hands out its URL), small enough for a contact image.
    static func avatar(_ note: LinkNotification) async -> Data? {
        guard let url = note.senderAvatar else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              LinkNotification.fileExtension(forContentType: http.value(forHTTPHeaderField: "Content-Type")) != nil,
              data.count < 2_000_000 else { return nil }
        return data
    }
}

struct Media: Sendable {
    var thumb: URL?
    var avatar: Data?
}

/// Hands iOS the notification exactly once, from whichever finishes first: the downloads, or
/// `serviceExtensionTimeWillExpire` (with the push as it came).
final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private let content: UNMutableNotificationContent
    private let note: LinkNotification
    private var handler: ((UNNotificationContent) -> Void)?

    init(content: UNMutableNotificationContent, note: LinkNotification,
         handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.note = note
        self.handler = handler
    }

    func deliver(_ media: Media?) {
        lock.withLock {
            guard let handler else { return }
            self.handler = nil
            handler(media.map(dressed) ?? content)
        }
    }

    private func dressed(_ media: Media) -> UNNotificationContent {
        if let file = media.thumb,
           let attachment = try? UNNotificationAttachment(identifier: "thumb", url: file) {
            content.attachments = [attachment]
        }
        guard let name = note.senderName else { return content }
        // As a message from the sender: iOS shows their photo (or initials) on the notification.
        let sender = INPerson(
            personHandle: INPersonHandle(value: note.senderID, type: .unknown), nameComponents: nil,
            displayName: name, image: media.avatar.map { INImage(imageData: $0) },
            contactIdentifier: nil, customIdentifier: note.senderID)
        let intent = INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
            speakableGroupName: note.chat.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: note.conversationID, serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return (try? content.updating(from: intent)) ?? content
    }
}
