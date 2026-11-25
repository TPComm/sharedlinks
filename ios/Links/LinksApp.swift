import AppIntents
import LinksKit
import SwiftUI
import UIKit
#if DEBUG
import CoreFoundation

private let testOpenURL = Notification.Name("LinksTestOpenURL")
#endif

@main
struct LinksApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel

    #if DEBUG
    /// Darwin notification name -> URL to open when it's posted (LINKS_TEST_OPEN_URLS, JSON).
    nonisolated private static let testOpenURLs: [String: String]? = ProcessInfo.processInfo.environment["LINKS_TEST_OPEN_URLS"]
        .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
    #endif

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LINKS_UI_TESTS"] == "1" {
            UIView.setAnimationsEnabled(false)
        }
        #endif
        let model = AppModel()
        _model = State(initialValue: model)
        #if DEBUG
        // XCTest relaunching or reopening the app terminates and re-finds its process, which a slow
        // CI Simulator fails at ("Failed to terminate", "does not have a process ID"). The UI tests
        // post these Darwin notifications instead (UITestApp.swift in LinksUITests).
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            exit(0)
        }, "com.tpcomm.links.ui-test-quit" as CFString, nil, .deliverImmediately)
        if AppModel.isUITesting, let routes = Self.testOpenURLs {
            for name in routes.keys {
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
                    guard let name = name?.rawValue as String?, let address = LinksApp.testOpenURLs?[name],
                          let url = URL(string: address) else { return }
                    DispatchQueue.main.async { NotificationCenter.default.post(name: testOpenURL, object: url) }
                }, name as CFString, nil, .deliverImmediately)
            }
        }
        #endif
        // Lets App Intents (e.g. "New Link") act on the running app.
        AppDependencyManager.shared.add(dependency: model)
        LinkTips.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    /// The tab and link pages showing, which the system keeps for this window: if iOS ends the
    /// app while TikTok is in front, coming back still lands on the link's page.
    @SceneStorage("navigation") private var savedNavigation: Data?
    @State private var restoredNavigation = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isSignedIn {
                InboxView()
                    .onAppear(perform: restoreNavigation)
                    .task(id: scenePhase) {
                        guard scenePhase == .active else { return }
                        model.showTourIfNeeded()
                        await model.loadAccount()
                        if let token = delegate.deviceToken { await model.registerDevice(token) }
                        await model.pollWhileActive()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                        model.showTourIfNeeded()
                    }
                    .task(id: scenePhase == .active ? model.featureTourRequest?.id : nil) {
                        guard scenePhase == .active, let id = model.featureTourRequest?.id else { return }
                        await model.presentFeatureTours(id)
                    }
                    .fullScreenCover(isPresented: $model.showTour, onDismiss: model.welcomeTourDismissed) {
                        TourView(start: model.tourStart)
                    }
                    .sheet(isPresented: Binding(get: { model.shouldPresentFeatureTours },
                                                set: { model.showFeatureTours = $0 }),
                           onDismiss: model.finishFeatureTours) {
                        if let request = model.featureTourRequest {
                            FeatureTourView(tours: request.tours)
                                .onAppear(perform: model.featureToursDidAppear)
                        }
                    }
            } else {
                SignInView()
            }
        }
        .onOpenURL { model.handle($0) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: testOpenURL)) { notification in
            if let url = notification.object as? URL { model.handle(url) }
        }
        #endif
        // Again for each sign-in: the token moves to whoever signed in on this phone.
        .task(id: "\(delegate.deviceToken ?? "")|\(model.isSignedIn)") {
            if let token = delegate.deviceToken { await model.registerDevice(token) }
        }
        .onChange(of: model.isSignedIn) { _, signedIn in
            if !signedIn { delegate.deviceToken = nil } // unregistered; signing in brings a new one
        }
        .onChange(of: delegate.openLinkID, initial: true) { _, id in
            guard let id, model.isSignedIn else { return }
            delegate.openLinkID = nil
            model.handle(DeepLink.open(linkID: id).url)
        }
        .onChange(of: delegate.refreshes) { Task { await model.refresh() } }
        .onChange(of: model.navigation) { _, navigation in
            savedNavigation = try? JSONEncoder().encode(navigation)
        }
        .alert("Couldn't Do That", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) { ToastView() }
    }

    private func restoreNavigation() {
        guard !restoredNavigation else { return }
        restoredNavigation = true
        #if DEBUG
        // Each UI test starts on the inbox, whatever an earlier test left showing. (XCUITest can't
        // stand in for iOS ending the app: apps it launches are never suspended, which is when the
        // system keeps a window's state. Checked by hand: background, `simctl terminate`, relaunch.)
        if ProcessInfo.processInfo.environment["LINKS_UI_TESTS"] == "1" { return }
        #endif
        guard let data = savedNavigation,
              let saved = try? JSONDecoder().decode(AppModel.Navigation.self, from: data) else { return }
        model.restore(saved)
    }
}

/// A short confirmation that slides up and fades, like the system's "Copied" HUD.
struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let message = model.toast {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation { model.toast = nil }
                    }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .sensoryFeedback(.success, trigger: model.toast) { _, new in new != nil }
    }
}
