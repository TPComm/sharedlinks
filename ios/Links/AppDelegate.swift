import LinksKit
import SwiftUI
import UIKit
import UserNotifications

/// Push notifications: registers with APNs and passes what the system says on to RootView, which
/// hands it to AppModel (registering the device, refreshing, opening a tapped link's page).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    /// This phone's APNs token (hex), once iOS has handed it over.
    @Published var deviceToken: String?
    /// The link a tapped notification is about, until RootView opens it.
    @Published var openLinkID: Int?
    /// Bumped by each notification that arrives while the app is in front.
    @Published var refreshes = 0

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([Self.newLinkCategory])
        // Signing in registers too (AppModel.signIn).
        if SessionStore.token != nil, !AppModel.isUITesting { application.registerForRemoteNotifications() }
        return true
    }

    /// The actions on a new-link push (#27), done from the notification without opening the app.
    static let newLinkCategory = UNNotificationCategory(
        identifier: LinkNotification.category,
        actions: [
            UNNotificationAction(identifier: LinkNotification.markWatchedAction, title: "Mark as Watched",
                                 icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")),
            UNTextInputNotificationAction(identifier: LinkNotification.commentAction, title: "Comment",
                                          icon: UNNotificationActionIcon(systemImageName: "bubble"),
                                          textInputButtonTitle: "Send", textInputPlaceholder: "Add a comment"),
        ],
        intentIdentifiers: [])

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Polling keeps the app up to date while it's open.
        print("Couldn't register for push notifications: \(error.localizedDescription)")
    }

    // The completion-handler forms, called back on the main thread: UIKit crashes ("Call must be
    // made on main thread") when the async forms return from the background.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        nonisolated(unsafe) let completionHandler = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.refreshes += 1 }
            completionHandler([.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = LinkNotification(userInfo: response.notification.request.content.userInfo)?.linkID
        let action = response.actionIdentifier
        let comment = (response as? UNTextInputNotificationResponse)?.userText
        nonisolated(unsafe) let completionHandler = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let id, action != UNNotificationDefaultActionIdentifier else {
                    if let id { self.openLinkID = id }
                    return completionHandler()
                }
                Task {
                    await Self.perform(action, on: id, comment: comment)
                    self.refreshes += 1
                    completionHandler()
                }
            }
        }
    }

    /// A notification action, straight to the server: iOS may have woken the app in the
    /// background just for this, before RootView or AppModel are around.
    static func perform(_ action: String, on linkID: Int, comment: String?) async {
        let client = APIClient()
        do {
            switch action {
            case LinkNotification.markWatchedAction: _ = try await client.setSeen(linkID, true)
            case LinkNotification.commentAction:
                let body = comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !body.isEmpty { _ = try await client.addComment(linkID, body: body) }
            default: break
            }
        } catch {
            print("Couldn't \(action) link \(linkID): \(error.localizedDescription)")
        }
    }
}
