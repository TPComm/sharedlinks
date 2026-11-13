import AuthenticationServices
import LinksKit
import SwiftUI
import UserNotifications
import WidgetKit

/// App state: the session, the inbox, and every action. Views stay thin.
@MainActor @Observable
final class AppModel {
    private(set) var token: String? = SessionStore.token
    private(set) var inbox: InboxState = InboxSnapshot.load() ?? .empty
    private(set) var claimable: [LinkUser] = []
    private(set) var isOffline = false
    private(set) var isSigningIn = false

    var tab: InboxTab = .toWatch
    var toast: String?
    var errorMessage: String?
    var showAddSheet = false
    var addPrefill = ""
    var showClaimSheet = false

    private var fastPollUntil = Date.distantPast
    /// Changes on every sign-in/out, so work that started under an old session can tell.
    private var sessionID = UUID()
    /// Bumped by every local change, so a poll that started before it doesn't undo it.
    private var localEdits = 0

    var isSignedIn: Bool { token != nil }
    var client: APIClient { APIClient(token: token) }
    /// The signed-in account, with email (the shared inbox only carries names and avatars).
    private(set) var account: LinkUser? = SessionStore.currentUser
    var me: LinkUser? { account ?? inbox.meUser }

    init() {
        #if DEBUG
        // Simulator/dev shortcut: launch with LINKS_DEV_TOKEN=<token from `server mint-session`>.
        if let devToken = ProcessInfo.processInfo.environment["LINKS_DEV_TOKEN"], !devToken.isEmpty,
           devToken != token {
            SessionStore.save(token: devToken)
            token = devToken
        }
        #endif
    }

    // MARK: Sign-in

    func signIn(with webAuth: WebAuthenticationSession, signUp: Bool = false) async {
        let pkce = PKCE()
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let callback = try await webAuth.authenticate(
                using: client.authorizeURL(pkce: pkce, signUp: signUp),
                callback: .customScheme(LinksConfig.urlScheme),
                preferredBrowserSession: .ephemeral,
                additionalHeaderFields: [:])
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if let error = value("error") {
                errorMessage = value("error_description") ?? "Sign-in failed (\(error))."
                return
            }
            guard value("state") == pkce.state, let code = value("code") else {
                errorMessage = "Sign-in was interrupted. Try again."
                return
            }
            let result = try await client.exchange(code: code, verifier: pkce.verifier)
            SessionStore.save(token: result.token, user: result.user)
            account = result.user
            token = result.token
            sessionID = UUID()
            claimable = result.claimable
            showClaimSheet = !claimable.isEmpty
            await refresh()
            WidgetCenter.shared.reloadAllTimelines() // even if the inbox happens to be empty
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The person closed the sheet.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        await client.signOut()
        endSession()
    }

    private func endSession() {
        sessionID = UUID()
        SessionStore.clear()
        InboxSnapshot.clear()
        ShareSuggestions.deleteAll()
        token = nil
        account = nil
        inbox = .empty
        claimable = []
        UNUserNotificationCenter.current().setBadgeCount(0)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Account

    func loadAccount() async {
        let session = sessionID
        guard isSignedIn, let me = try? await client.me(), session == sessionID else { return }
        setAccount(me.user)
        claimable = me.claimable
    }

    /// Throws rather than using the app-wide alert, which would close ClaimSheet.
    func claim(_ legacy: LinkUser) async throws {
        do {
            let me = try await client.claim(legacy.id)
            setAccount(me.user)
            claimable = me.claimable
            showClaimSheet = false
            toast = "Welcome back, \(me.user.name)"
            await refresh()
        } catch APIError.signedOut {
            endSession() // closes the sheet along with the inbox
        } catch {
            // Someone else may have claimed that person meanwhile; don't offer them again.
            await loadAccount()
            throw error
        }
    }

    func rename(to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await perform {
            let me = try await self.client.rename(to: name)
            self.setAccount(me.user)
            await self.refresh()
        }
    }

    private func setAccount(_ user: LinkUser) {
        SessionStore.currentUser = user
        account = user
    }

    // MARK: Sync

    func refresh() async {
        guard isSignedIn else { return }
        let session = sessionID
        let edits = localEdits
        do {
            let state = try await client.state()
            // Signed out meanwhile, or this response predates a local change: drop it; the next
            // poll brings the server's view including that change.
            guard session == sessionID, edits == localEdits else { return }
            isOffline = false
            if state != inbox { setInbox(state) }
        } catch is CancellationError {
            // The scene went inactive; not an outage.
        } catch let error as URLError where error.code == .cancelled {
        } catch APIError.signedOut {
            if session == sessionID { endSession() }
        } catch {
            if session == sessionID { isOffline = true }
        }
    }

    /// Poll while the app is in the foreground; faster right after adding (previews arrive).
    func pollWhileActive() async {
        while !Task.isCancelled {
            await refresh()
            let interval: Duration = fastPollUntil > .now ? .seconds(1.5) : .seconds(8)
            try? await Task.sleep(for: interval)
        }
    }

    private func setInbox(_ state: InboxState) {
        guard isSignedIn else { return }
        inbox = state
        InboxSnapshot.save(state)
        ThumbnailStore.prune(keeping: Set(state.links.map(\.id)))
        UNUserNotificationCenter.current().setBadgeCount(state.toWatch.count)
        // Any change can matter to some widget (To Watch, Sent receipts, a preview title arriving).
        // Reloads requested while the app is in the foreground don't count against the budget.
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func patch(_ link: SharedLink) {
        localEdits += 1
        var state = inbox
        if let i = state.links.firstIndex(where: { $0.id == link.id }) {
            state.links[i] = link
        } else {
            state.links.insert(link, at: 0)
        }
        setInbox(state)
    }

    /// The app icon badge shows the To Watch count. iOS only asks once; later calls are no-ops.
    func requestBadgePermission() {
        #if DEBUG
        // No system prompt in UI tests: while it's up the app is inactive and doesn't fetch, and a
        // fresh CI Simulator shows it whenever it likes (ios/scripts/ui-tests.sh).
        if ProcessInfo.processInfo.environment["LINKS_UI_TESTS"] == "1" { return }
        #endif
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) }
    }

    // MARK: Actions

    @discardableResult
    func add(_ text: String, note: String = "") async -> Bool {
        do {
            try await send(text, note: note)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// `add` without the app-wide alert, for the New Link sheet: RootView's alert would close
    /// the sheet and lose what was typed, so the sheet shows the error over itself.
    func send(_ text: String, note: String = "") async throws {
        let result = try await client.add(text, note: note)
        patch(result.link)
        if result.duplicate {
            let link = result.link
            toast = inbox.isMine(link)
                ? "You already added this one"
                : "Already here: \(inbox.name(of: link.addedBy)) sent it \(LinkFormat.ago(link.addedAt).lowercased())"
        } else {
            toast = "Sent"
            if tab != .search { tab = .sent }
            fastPollUntil = .now.addingTimeInterval(15)
            ShareSuggestions.donateSend(in: inbox)
        }
    }

    func setSeen(_ link: SharedLink, _ seen: Bool) async {
        let me = inbox.me
        var optimistic = link
        optimistic.seen[me] = seen ? .now : nil
        let mark = optimistic.seen[me]
        await patchOptimistically(optimistic, undo: { now in
            guard now.seen[me] == mark else { return nil }
            var restored = now
            restored.seen[me] = link.seen[me]
            return restored
        }) { try await self.client.setSeen(link.id, seen) }
    }

    func react(_ link: SharedLink, _ emoji: String) async {
        let me = inbox.me
        let next = link.reactions[me] == emoji ? nil : emoji
        var optimistic = link
        optimistic.reactions[me] = next
        await patchOptimistically(optimistic, undo: { now in
            guard now.reactions[me] == next else { return nil }
            var restored = now
            restored.reactions[me] = link.reactions[me]
            return restored
        }) { try await self.client.react(link.id, next) }
    }

    /// Shows `optimistic` at once, then saves it. The server's copy is applied only if nothing
    /// newer was patched meanwhile: a later tap already shows the right state, and the next poll
    /// brings anything else. If saving fails, `undo` rolls back this one change (returning nil when
    /// something newer has replaced it), since offline the refresh that follows can't.
    private func patchOptimistically(_ optimistic: SharedLink,
                                     undo: @escaping (SharedLink) -> SharedLink?,
                                     save: @escaping () async throws -> SharedLink) async {
        patch(optimistic)
        let edits = localEdits
        await perform(onFailure: {
            if let now = self.inbox.links.first(where: { $0.id == optimistic.id }), let restored = undo(now) {
                self.patch(restored)
            }
        }) {
            let saved = try await save()
            if edits == self.localEdits { self.patch(saved) }
        }
    }

    func setNote(_ link: SharedLink, _ note: String) async {
        await perform { self.patch(try await self.client.setNote(link.id, note)) }
    }

    func delete(_ link: SharedLink) async {
        localEdits += 1
        var state = inbox
        state.links.removeAll { $0.id == link.id }
        setInbox(state)
        await perform { try await self.client.delete(link.id) }
    }

    /// Open in TikTok/Instagram/YouTube (universal links), and count it as watched.
    func open(_ link: SharedLink, with openURL: OpenURLAction) {
        if inbox.isUnwatched(link) {
            // Send the mark before leaving: once TikTok is in front, this app gets suspended.
            // (One short request, well inside the background time iOS grants.)
            let app = UIApplication.shared
            let background = app.beginBackgroundTask(withName: "Mark watched", expirationHandler: nil)
            Task {
                await setSeen(link, true)
                app.endBackgroundTask(background)
            }
        }
        openURL(link.url)
    }

    func handle(_ url: URL, openURL: OpenURLAction) {
        switch DeepLink(url: url) {
        case .open(let id):
            if let link = inbox.links.first(where: { $0.id == id }) {
                open(link, with: openURL)
            } else {
                // From a widget that saw a newer inbox than this (backgrounded) app has.
                Task {
                    await refresh()
                    if let link = inbox.links.first(where: { $0.id == id }) { open(link, with: openURL) }
                }
            }
        case .add:
            addPrefill = ""
            showAddSheet = true
        case .inbox, nil:
            break
        }
    }

    private func perform(onFailure: (() -> Void)? = nil, _ work: @escaping () async throws -> Void) async {
        do {
            try await work()
        } catch APIError.signedOut {
            endSession()
        } catch {
            errorMessage = error.localizedDescription
            onFailure?()     // offline, the refresh below can't replace an optimistic change
            await refresh()  // refused, the server's copy wins anyway
        }
    }
}
