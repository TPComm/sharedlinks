import AppIntents
import LinksKit
import SwiftUI

@main
struct LinksApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
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
                        model.requestBadgePermission()
                        await model.loadAccount()
                        await model.pollWhileActive()
                    }
                    .fullScreenCover(isPresented: $model.showTour) {
                        TourView(start: model.tourStart)
                    }
            } else {
                SignInView()
            }
        }
        .onOpenURL { model.handle($0) }
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
