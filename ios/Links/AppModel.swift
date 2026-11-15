import AuthenticationServices
import LinksKit
import SwiftUI
import TipKit
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
    private(set) var isDeletingAccount = false

    var tab: InboxTab = .toWatch
    /// Each tab's stack of link pages, by link id. Kept here, not in the views, so a widget can
    /// open a page, and saved in SceneStorage (RootView) so coming back from TikTok lands on the
    /// same page even if iOS ended the app meanwhile.
    var paths: [InboxTab: [Int]] = [:]
    var toast: String?
    var errorMessage: String?
    var showAddSheet = false
    var addPrefill = ""
    var showClaimSheet = false
    var showTour = false
    /// Set by ProfileButton while the profile sheet is up.
    var isProfileOpen = false
    /// The page the tour opens on: the first, or the share-sheet page from "How to Share to Links".
    private(set) var tourStart: TourPage = .welcome
    private(set) var tourCompleted = Onboarding.shared.hasCompletedTour

    private var fastPollUntil = Date.distantPast
    /// The server sends push notifications for this phone, so polling can be slower.
    private var pushRegistered = false
    private var registeredToken: String?
    /// Changes on every sign-in/out, so work that started under an old session can tell.
    private var sessionID = UUID()
    /// Bumped by every local change, so a poll that started before it doesn't undo it.
    private var localEdits = 0
    /// Like localEdits, per link: a save's reply is dropped only if that link changed since.
    private var linkEdits: [Int: Int] = [:]

    var isSignedIn: Bool { token != nil }
    var client: APIClient { APIClient(token: token) }
    /// The signed-in account, with email (the shared inbox only carries names and avatars).
    private(set) var account: LinkUser? = SessionStore.currentUser
    var me: LinkUser? { account ?? inbox.meUser }
    /// The token from an invite link opened while signed out, kept until a sign-in sends it (#5).
    private(set) var pendingInvite: String?
    /// Invites I sent that nobody has used yet (the People sheet).
    private(set) var invites: [Invite] = []

    /// UI tests launch with LINKS_UI_TESTS=1: no tour, tips or notification prompt to get in their way.
    static let isUITesting: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["LINKS_UI_TESTS"] == "1"
        #else
        false
        #endif
    }()

    /// LINKS_RESET_ONBOARDING=1 starts from a first launch: the tour, the share-sheet step and the
    /// tips all show again (the tour's UI test).
    static let resetsOnboarding: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["LINKS_RESET_ONBOARDING"] == "1"
        #else
        false
        #endif
    }()

    init() {
        if Self.resetsOnboarding {
            Onboarding.shared.reset()
            tourCompleted = false
        }
        #if DEBUG
        // LINKS_HOLD_PRACTICE_CONFIRMATION=1: the Share Extension keeps practice Send's confirmation up
        // until it's tapped (the tour's UI test). Written every launch, so it never outlives the test.
        Onboarding.shared.holdsPracticeConfirmation =
            ProcessInfo.processInfo.environment["LINKS_HOLD_PRACTICE_CONFIRMATION"] == "1"
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
            let result = try await client.exchange(code: code, verifier: pkce.verifier, invite: pendingInvite)
            pendingInvite = nil
            SessionStore.save(token: result.token, user: result.user)
            account = result.user
            token = result.token
            sessionID = UUID()
            claimable = result.claimable
            showClaimSheet = !claimable.isEmpty
            await refresh()
            WidgetCenter.shared.reloadAllTimelines() // even if the inbox happens to be empty
            if !Self.isUITesting { UIApplication.shared.registerForRemoteNotifications() }
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
        showTour = false
        pushRegistered = false
        registeredToken = nil
        SessionStore.clear()
        InboxSnapshot.clear()
        ThumbnailCache.clear()
        URLCache.shared.removeAllCachedResponses() // thumbnails and avatars this session fetched
        ShareSuggestions.deleteAll()
        token = nil
        account = nil
        inbox = .empty
        claimable = []
        invites = []
        paths = [:]
        UNUserNotificationCenter.current().setBadgeCount(0)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications() // names and titles from this account
        // Even if the server never heard about the sign-out (offline), this phone stops showing pushes.
        // Signing in registers again.
        if !Self.isUITesting { UIApplication.shared.unregisterForRemoteNotifications() }
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

    /// Throws so the profile can say what went wrong over itself: RootView's alert would close it.
    func rename(to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let me = try await client.rename(to: name)
            setAccount(me.user)
        } catch APIError.signedOut {
            endSession()
            return
        }
        await refresh()
    }

    // MARK: Invites

    func loadInvites() async {
        await perform { self.invites = try await self.client.invites() }
    }

    /// Throws so the invite sheet can say what went wrong where the person is looking.
    func createInvite(email: String) async throws -> Invite {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let invite = try await client.createInvite(email: email.isEmpty ? nil : email)
            invites.insert(invite, at: 0)
            return invite
        } catch APIError.signedOut {
            endSession()
            throw APIError.signedOut
        }
    }

    func revokeInvite(_ invite: Invite) async {
        let before = invites
        invites.removeAll { $0.id == invite.id }
        await perform(onFailure: { self.invites = before }) {
            self.invites = try await self.client.revokeInvite(invite.id)
        }
    }

    /// Deletes the account on the server (and the links it sent, for everyone), then
    /// forgets everything on this device: what signing out does, plus this app's settings.
    /// Throws, like `rename`, for the profile to show.
    func deleteAccount() async throws {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await client.deleteAccount()
        } catch APIError.signedOut {
            endSession()
            errorMessage = "You were signed out, so your account wasn't deleted. Sign in, then try again."
            return
        }
        endSession()
        // Settings kept across sign-outs (e.g. what's been shown once) go too: a new account
        // on this device starts fresh.
        if let group = LinksConfig.appGroup {
            UserDefaults(suiteName: group)?.removePersistentDomain(forName: group)
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        toast = "Account deleted"
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

    /// Poll while the app is in the foreground; faster right after adding (previews arrive), and
    /// slower when push notifications bring new links and badge changes.
    func pollWhileActive() async {
        while !Task.isCancelled {
            await refresh()
            let interval: Duration = if fastPollUntil > .now {
                .seconds(1.5)
            } else if await pushesArrive() {
                .seconds(45)
            } else {
                .seconds(8)
            }
            try? await Task.sleep(for: interval)
        }
    }

    private func pushesArrive() async -> Bool {
        guard pushRegistered else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().alertSetting == .enabled
    }

    /// Sends the server this phone's APNs token. A failure just leaves polling as it was.
    /// Again each time the app comes to the front until it works, so a failed attempt isn't final.
    func registerDevice(_ deviceToken: String) async {
        guard isSignedIn, registeredToken != deviceToken else { return }
        let session = sessionID
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        do {
            let push = try await client.registerDevice(token: deviceToken, env: env)
            if session == sessionID {
                pushRegistered = push
                registeredToken = deviceToken
            }
        } catch {
            print("Couldn't register this device for push notifications: \(error.localizedDescription)")
        }
    }

    private func setInbox(_ state: InboxState) {
        guard isSignedIn else { return }
        inbox = state
        InboxSnapshot.save(state)
        ShareSuggestions.seedIfNeeded(in: state)
        ThumbnailStore.prune(keeping: state.links)
        UNUserNotificationCenter.current().setBadgeCount(state.toWatch.count)
        // Any change can matter to some widget (To Watch, Sent receipts, a preview title arriving).
        // Reloads requested while the app is in the foreground don't count against the budget.
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func patch(_ link: SharedLink) {
        localEdits += 1
        linkEdits[link.id, default: 0] += 1
        var state = inbox
        if let i = state.links.firstIndex(where: { $0.id == link.id }) {
            state.links[i] = link
        } else {
            state.links.insert(link, at: 0)
        }
        setInbox(state)
    }

    /// Notifications for new links and reactions, and the To Watch count on the app icon. iOS only
    /// asks once; later calls are no-ops (Settings changes it: the tour and the profile link there).
    func requestNotificationPermission() {
        // No system prompt in UI tests: while it's up the app is inactive and doesn't fetch, and a
        // fresh CI Simulator shows it whenever it likes (ios/scripts/ui-tests.sh).
        // Nor over the tour: its last page offers it, and finishTour asks if that wasn't used.
        guard !Self.isUITesting, tourCompleted else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) }
    }

    // MARK: Tour

    /// Gesture tips wait until nothing covers the inbox, so a popover never lands under a sheet.
    var canShowTips: Bool { tourCompleted && !showTour && !showClaimSheet && !showAddSheet && !isProfileOpen }

    /// Shows the tour once, after sign-in and after the claim sheet (if any) has closed.
    func showTourIfNeeded() {
        guard isSignedIn, !tourCompleted, !showTour, !showClaimSheet, !showAddSheet, !Self.isUITesting else { return }
        startTour()
    }

    func startTour(at page: TourPage = .welcome) {
        tourStart = page
        showTour = true
    }

    /// Done or skipped: either way it doesn't come back by itself.
    func finishTour() {
        Onboarding.shared.completeTour()
        tourCompleted = true
        showTour = false
        requestNotificationPermission()
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
        ReactTip().invalidate(reason: .actionPerformed)
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

    /// Shows `optimistic` at once, then saves it. The server's copy is applied only if that link
    /// wasn't patched again meanwhile: a later tap already shows the right state, and the next poll
    /// brings anything else. If saving fails, `undo` rolls back this one change (returning nil when
    /// something newer has replaced it), since offline the refresh that follows can't.
    private func patchOptimistically(_ optimistic: SharedLink,
                                     undo: @escaping (SharedLink) -> SharedLink?,
                                     save: @escaping () async throws -> SharedLink) async {
        patch(optimistic)
        let edits = linkEdits[optimistic.id]
        await perform(onFailure: {
            if let now = self.inbox.links.first(where: { $0.id == optimistic.id }), let restored = undo(now) {
                self.patch(restored)
            }
        }) {
            let saved = try await save()
            if edits == self.linkEdits[optimistic.id] { self.patch(saved) }
        }
    }

    func setNote(_ link: SharedLink, _ note: String) async {
        await perform { self.patch(try await self.client.setNote(link.id, note)) }
    }

    /// "Try Loading the Preview Again" on a link whose preview failed.
    func refreshPreview(_ link: SharedLink) async {
        await perform { self.patch(try await self.client.refreshPreview(link.id)) }
        fastPollUntil = .now.addingTimeInterval(15)
    }

    func delete(_ link: SharedLink) async {
        localEdits += 1
        linkEdits[link.id, default: 0] += 1
        var state = inbox
        state.links.removeAll { $0.id == link.id }
        setInbox(state)
        await perform { try await self.client.delete(link.id) }
    }

    // MARK: Reports and blocks

    /// Shows the server's view after a report or block straight away (lists, badge, widgets).
    private func applyLocally(_ change: (InboxState) -> InboxState) {
        localEdits += 1
        setInbox(change(inbox))
    }

    /// Reports someone else's link. It's hidden for me only; the server's owner reads the report.
    func report(_ link: SharedLink, reason: ReportReason) async {
        applyLocally { $0.hiding(link: link.id) }
        await perform {
            try await self.client.report(link: link.id, reason: reason)
            self.toast = "Reported. It's hidden for you."
        }
    }

    /// One-way: I stop seeing their links, marks and reactions. They aren't told.
    func block(_ person: LinkUser, alsoReport: Bool) async {
        applyLocally { $0.blocking(person.id) }
        await perform {
            if alsoReport { try await self.client.report(person: person.id, reason: .other) }
            _ = try await self.client.block(person.id)
            self.toast = alsoReport ? "Blocked and reported \(person.name)" : "Blocked \(person.name)"
        }
    }

    func unblock(_ person: LinkUser) async {
        applyLocally { $0.unblocking(person.id) }
        await perform {
            _ = try await self.client.unblock(person.id)
            self.toast = "Unblocked \(person.name)"
        }
        await refresh() // brings their links, marks and reactions back
    }

    /// Opens it in TikTok (or wherever; universal links) and counts it as watched, from a link's
    /// page or a row's long-press menu. A page stays underneath, with Mark as Not Watched to undo.
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

    func handle(_ url: URL) {
        switch DeepLink(url: url) {
        case .open(let id):
            // The link's page, not TikTok straight away (see DeepLink.open).
            if let link = inbox.links.first(where: { $0.id == id }) {
                showPage(link)
            } else {
                // From a widget that saw a newer inbox than this (backgrounded) app has.
                Task {
                    await refresh()
                    if let link = inbox.links.first(where: { $0.id == id }) { showPage(link) }
                }
            }
        case .add:
            addPrefill = ""
            showAddSheet = true
        case .invite(let invite):
            // Signed in already: they're in, so there's nothing to use it for.
            if token == nil {
                pendingInvite = invite
                errorMessage = nil
            }
        // The server's universal links, handled once link pages and chats ship.
        case .inbox, .link, .group, nil:
            break
        }
    }

    // MARK: Navigation

    /// A row's link page, on top of that row's list.
    func showPage(_ link: SharedLink, on tab: InboxTab) {
        paths[tab] = [link.id]
    }

    /// A link's page on the tab whose list has it, e.g. from a widget.
    func showPage(_ link: SharedLink) {
        let tab = InboxTab(inbox.home(of: link))
        self.tab = tab
        paths[tab] = [link.id]
    }

    /// What RootView keeps in SceneStorage.
    struct Navigation: Codable, Equatable {
        var tab: InboxTab
        var paths: [InboxTab: [Int]]
    }

    var navigation: Navigation { Navigation(tab: tab, paths: paths) }

    /// Puts back the tab and pages that were showing when iOS ended the app, minus links that
    /// have gone since. A page a widget already opened wins.
    func restore(_ saved: Navigation) {
        guard paths.values.allSatisfy(\.isEmpty) else { return }
        let ids = Set(inbox.links.map(\.id))
        tab = saved.tab
        paths = saved.paths.mapValues { $0.filter(ids.contains) }
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
