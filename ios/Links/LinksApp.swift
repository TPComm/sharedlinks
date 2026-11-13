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
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if model.isSignedIn {
                InboxView()
                    .task(id: scenePhase) {
                        guard scenePhase == .active else { return }
                        model.requestBadgePermission()
                        await model.loadAccount()
                        await model.pollWhileActive()
                    }
            } else {
                SignInView()
            }
        }
        .onOpenURL { model.handle($0, openURL: openURL) }
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
