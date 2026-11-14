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
        // Signing in registers too (AppModel.signIn).
        if SessionStore.token != nil, !AppModel.isUITesting { application.registerForRemoteNotifications() }
        return true
    }

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
        let id = response.notification.request.content.userInfo["link_id"] as? Int
        nonisolated(unsafe) let completionHandler = completionHandler
        DispatchQueue.main.async {
            if let id { MainActor.assumeIsolated { self.openLinkID = id } }
            completionHandler()
        }
    }
}
