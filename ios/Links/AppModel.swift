import AuthenticationServices
import LinksKit
import OSLog
import SwiftUI
import TipKit
import UserNotifications
import WidgetKit

private let tourLog = Logger(subsystem: "com.tpcomm.links", category: "onboarding")

/// App state: the session, the inbox, and every action. Views stay thin.
@MainActor @Observable
final class AppModel {
    let sharedHighlights = SharedHighlights()
    private(set) var token: String? = SessionStore.token
    private(set) var inbox: InboxState = InboxSnapshot.load() ?? .empty
    /// A successful poll can carry comment edits without changing the inbox's activity summary.
    private(set) var inboxRefresh = 0
    private(set) var claimable: [LinkUser] = []
    /// My push settings for links I sent, as the switches show them; nil until the server says,
    /// or on a server too old to have them.
    private(set) var notifications: NotificationSettings?
    /// The server's copy as of the last save or load, which a failed save goes back to.
    private var savedNotifications: NotificationSettings?
    /// The latest save: each waits for the one before, so they reach the server in tap order.
    private var notificationSave: Task<MeResponse, Error>?
    private let chatMuteSaves = ChatMuteSaveQueue()
    private(set) var isOffline = false
    private(set) var isSigningIn = false
    private(set) var isDeletingAccount = false

    var tab: InboxTab = .toWatch
    /// The chat the lists show; `nil` is all of them. The To Watch badge always counts every chat.
    var chat: Int?
    /// The chat sheet showing, from the inbox's chat picker.
    var chatSheet: ChatSheet?
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
    var showFeatureTours = false
    /// Swipe Through, while it's open.
    var swipeQueue: SwipeQueue?
    private(set) var pendingFeatureTours: [FeatureTour] = []
    private var dismissingWelcomeTour = false
    private var requestingNotifications = false
    private var finishedNotificationPermission = false
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
    /// Like localEdits, for the notification settings.
    private var notificationEdits = 0
    private var commentReads = CommentReadState.load()

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
            FeatureTours.shared.reset()
            tourCompleted = false
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LINKS_RESET_FEATURE_TOURS"] == "1" {
            FeatureTours.shared.reset()
        }
        if ProcessInfo.processInfo.environment["LINKS_COMPLETE_ONBOARDING"] == "1" {
            Onboarding.shared.completeTour()
            tourCompleted = true
        }
        if ProcessInfo.processInfo.environment["LINKS_TEST_OPEN_NEW_LINK_ON_LAUNCH"] == "1" {
            showAddSheet = true
        }
        // Extensions don't inherit the UI test runner's environment.
        LinksConfig.sharedDefaults.set(
            ProcessInfo.processInfo.environment["LINKS_DEV_TOKEN"] != nil
                ? ProcessInfo.processInfo.environment["LINKS_SERVER_URL"] : nil,
            forKey: "links.uiTests.serverURL")
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
            if let id = result.groupID, inbox.group(id) != nil { showChat(id) }
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
        showFeatureTours = false
        swipeQueue = nil
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
        notifications = nil
        savedNotifications = nil
        notificationSave = nil
        invites = []
        paths = [:]
        chat = nil
        chatSheet = nil
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
        let edits = notificationEdits
        guard isSignedIn, let me = try? await client.me(), session == sessionID else { return }
        setAccount(me.user)
        claimable = me.claimable
        if edits == notificationEdits { setNotificationsFromServer(me.notifications) }
    }

    private func setNotificationsFromServer(_ settings: NotificationSettings?) {
        notifications = settings
        savedNotifications = settings
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
        let edits = notificationEdits
        do {
            let me = try await client.rename(to: name)
            setAccount(me.user)
            if edits == notificationEdits, me.notifications != nil { setNotificationsFromServer(me.notifications) }
        } catch APIError.signedOut {
            endSession()
            return
        }
        await refresh()
    }

    /// Uploads `data` from the photo picker as my avatar (#97), squared and shrunk first. Throws,
    /// like `rename`, for the profile to show.
    func setPhoto(_ data: Data) async throws {
        let session = sessionID
        guard let jpeg = await Task.detached(operation: { ProfilePhoto.jpeg(from: data) }).value else {
            throw APIError.server("That photo couldn't be opened. Try another one.")
        }
        guard session == sessionID else { return }
        try await savePhoto(session) { try await $0.setPhoto(jpeg) }
    }

    func removePhoto() async throws {
        try await savePhoto(sessionID) { try await $0.removePhoto() }
    }

    /// A reply that lands after Sign Out (still available while a photo saves) is dropped, so it
    /// can't put the old account back.
    private func savePhoto(_ session: UUID, _ save: (APIClient) async throws -> MeResponse) async throws {
        do {
            let me = try await save(client)
            guard session == sessionID else { return }
            setAccount(me.user)
        } catch APIError.signedOut {
            if session == sessionID { endSession() }
            return
        } catch {
            guard session == sessionID else { return }
            throw error
        }
        await refresh() // my avatar on the links I sent
    }

    /// Shows the change at once. Once the last tap's save is done, the switches show the server's
    /// copy, so a failed save is undone. Throws, like `rename`, for the profile to show.
    func setNotifications(watched: Bool? = nil, reactions: Bool? = nil) async throws {
        guard var next = notifications else { return }
        if let watched { next.watched = watched }
        if let reactions { next.reactions = reactions }
        notifications = next
        notificationEdits += 1
        let edits = notificationEdits
        let session = sessionID
        let client = client
        let previous = notificationSave
        let save = Task {
            _ = await previous?.result
            return try await client.setNotifications(watched: watched, reactions: reactions)
        }
        notificationSave = save
        do {
            let me = try await save.value
            guard session == sessionID else { return }
            if let saved = me.notifications { savedNotifications = saved }
            if edits == notificationEdits { notifications = savedNotifications }
        } catch APIError.signedOut {
            if session == sessionID { endSession() }
        } catch {
            // Saves finish in order, so after the last one the server's copy is settled.
            if session == sessionID, edits == notificationEdits { notifications = savedNotifications }
            throw error
        }
    }

    // MARK: Invites

    func loadInvites() async {
        await perform { self.invites = try await self.client.invites() }
    }

    private func acceptInvite(_ invite: String) async {
        await perform {
            let group = try await self.client.acceptInvite(invite)
            await self.refresh()
            if let id = group?.id, self.inbox.group(id) != nil { self.showChat(id) }
        }
    }

    /// Throws so the invite sheet can say what went wrong where the person is looking.
    func createInvite(email: String, groupID: Int?) async throws -> Invite {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let invite = try await client.createInvite(email: email.isEmpty ? nil : email, groupID: groupID)
            invites.insert(invite, at: 0)
            return invite
        } catch APIError.signedOut {
            endSession()
            throw APIError.signedOut
        }
    }

    /// Throws so People can say what went wrong over itself: the app-wide alert would close the profile.
    func revokeInvite(_ invite: Invite) async throws {
        let before = invites
        invites.removeAll { $0.id == invite.id }
        do {
            invites = try await client.revokeInvite(invite.id)
        } catch APIError.signedOut {
            endSession()
            throw APIError.signedOut
        } catch {
            // Refused because it was used or cancelled elsewhere: the server's list drops it.
            // Offline, it's still pending, so it goes back.
            invites = (try? await client.invites()) ?? before
            throw error
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
            inboxRefresh += 1
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
        // Left on another device, or emptied: back to all chats.
        if let chat, state.group(chat) == nil { self.chat = nil }
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

    private func requestNotificationPermission() {
        if finishedNotificationPermission {
            showFeatureToursIfNeeded()
            return
        }
        if let reason = automaticFeatureTourBlocker {
            tourLog.debug("Deferring notification permission check: \(reason, privacy: .public)")
            return
        }
        requestingNotifications = true

        // The system request isn't cancellable. Give SpringBoard time on cold boots, but don't
        // leave onboarding stuck if it never answers. Presentation still waits for activation.
        let timeout = Task {
            try await Task.sleep(for: .seconds(75))
            tourLog.notice("Notification authorization timed out; continuing onboarding when active")
            finishNotificationPermission()
        }
        Task {
            defer { timeout.cancel() }
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard !finishedNotificationPermission else { return }
            if status != .notDetermined {
                tourLog.notice("Skipping notification request; authorization status is \(status.rawValue, privacy: .public)")
                finishNotificationPermission()
                return
            }

            // Foreground and sheet state can change while fetching settings.
            requestingNotifications = false
            if let reason = automaticFeatureTourBlocker {
                tourLog.notice("Deferring notification request: \(reason, privacy: .public)")
                return
            }
            requestingNotifications = true
            tourLog.notice("Starting notification authorization request")
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                tourLog.notice("Notification authorization returned; granted=\(granted, privacy: .public)")
            } catch {
                tourLog.error("Notification authorization returned an error: \(error, privacy: .public)")
            }
            finishNotificationPermission()
        }
    }

    private func finishNotificationPermission() {
        guard !finishedNotificationPermission else { return }
        requestingNotifications = false
        finishedNotificationPermission = true
        showFeatureToursIfNeeded()
    }

    // MARK: Comments

    func hasUnreadComments(_ link: SharedLink) -> Bool {
        commentReads.hasUnread(link, person: inbox.me, server: client.baseURL)
    }

    func markCommentsRead(_ linkID: Int, comments: [LinkComment]) {
        guard let date = comments.map(\.createdAt).max() else { return }
        commentReads.markRead(linkID, through: date, person: inbox.me, server: client.baseURL)
        commentReads.save()
    }

    func loadComments(_ linkID: Int) async throws -> [LinkComment] {
        let session = sessionID
        do {
            let comments = try await client.comments(linkID)
            guard session == sessionID else { throw CancellationError() }
            return comments
        } catch APIError.signedOut {
            if session == sessionID { endSession() }
            throw APIError.signedOut
        }
    }

    func saveComment(_ linkID: Int, comment: LinkComment?, body: String) async throws {
        try await changeComment {
            if let comment {
                _ = try await self.client.editComment(comment.id, body: body)
            } else {
                _ = try await self.client.addComment(linkID, body: body)
            }
        }
    }

    func deleteComment(_ comment: LinkComment) async throws {
        try await changeComment { try await self.client.deleteComment(comment.id) }
    }

    func reportComment(_ comment: LinkComment, reason: ReportReason) async throws {
        try await changeComment { try await self.client.report(comment: comment.id, reason: reason) }
        toast = "Comment reported"
    }

    private func changeComment(_ work: () async throws -> Void) async throws {
        let session = sessionID
        do {
            try await work()
            guard session == sessionID else { throw CancellationError() }
            localEdits += 1
            await refresh()
        } catch APIError.signedOut {
            if session == sessionID { endSession() }
            throw APIError.signedOut
        }
    }

    // MARK: Tour

    /// Gesture tips wait until nothing covers the inbox, so a popover never lands under a sheet.
    var canShowTips: Bool { tourCompleted && !showTour && !showFeatureTours && swipeQueue == nil && !dismissingWelcomeTour && !requestingNotifications && !showClaimSheet && !showAddSheet && !isProfileOpen }

    /// Starts onboarding after sign-in and after the claim sheet (if any) has closed.
    func showTourIfNeeded() {
        if tourCompleted {
            requestNotificationPermission()
            return
        }
        guard isSignedIn, !showTour, !showFeatureTours, !showClaimSheet, !showAddSheet, !isProfileOpen, chatSheet == nil, !Self.isUITesting else { return }
        startTour()
    }

    private var automaticFeatureTourBlocker: String? {
        if Self.isUITesting { return "UI testing" }
        if !isSignedIn { return "signed out" }
        if UIApplication.shared.applicationState != .active { return "application inactive" }
        if !tourCompleted { return "welcome tour incomplete" }
        if showTour || dismissingWelcomeTour { return "welcome tour presenting or dismissing" }
        if requestingNotifications { return "notification authorization pending" }
        if showFeatureTours { return "feature tour already open" }
        if showClaimSheet { return "claim sheet open" }
        if showAddSheet { return "add sheet open" }
        if isProfileOpen { return "profile open" }
        if chatSheet != nil { return "chat sheet open" }
        if swipeQueue != nil { return "Swipe Through open" }
        return nil
    }

    private func showFeatureToursIfNeeded() {
        if let reason = automaticFeatureTourBlocker {
            tourLog.notice("Deferring feature tour: \(reason, privacy: .public)")
            return
        }
        let unseenTours = FeatureTour.allCases.filter { !FeatureTours.shared.hasSeen($0.id) }
        guard !unseenTours.isEmpty else {
            tourLog.notice("Skipping feature tour: all features seen")
            return
        }
        startFeatureTours(unseenTours)
    }

    func startFeatureTours(_ tours: [FeatureTour] = FeatureTour.allCases) {
        guard !tours.isEmpty else { return }
        pendingFeatureTours = tours
        showFeatureTours = true
    }

    func finishFeatureTours() {
        for tour in pendingFeatureTours { FeatureTours.shared.markSeen(tour.id) }
        pendingFeatureTours = []
        requestNotificationPermission()
    }

    func welcomeTourDismissed() {
        // Don't start another presentation inside SwiftUI's dismissal transaction.
        DispatchQueue.main.async {
            self.dismissingWelcomeTour = false
            self.requestNotificationPermission()
        }
    }

    func startTour(at page: TourPage = .welcome) {
        tourStart = page
        showTour = true
    }

    /// Done or skipped: either way it doesn't come back by itself.
    func finishTour() {
        Onboarding.shared.completeTour()
        tourCompleted = true
        dismissingWelcomeTour = true
        showTour = false
    }

    // MARK: Actions

    @discardableResult
    func add(_ text: String, note: String = "") async -> Bool {
        do {
            try await send(text, note: note, groupID: chat)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// `add` without the app-wide alert, for the New Link sheet: RootView's alert would close
    /// the sheet and lose what was typed, so the sheet shows the error over itself.
    /// `groupID` is the chat it goes to; `nil` lets the server pick the default one.
    func send(_ text: String, note: String = "", groupID: Int? = nil) async throws {
        let result = try await client.add(text, note: note, groupID: groupID)
        patch(result.link)
        // Sent to a chat other than the one the lists show: show that one, so the link is there.
        if let chat, result.link.groupID != chat { self.chat = result.link.groupID }
        if result.duplicate {
            let link = result.link
            toast = inbox.isMine(link)
                ? "You already added this one"
                : "Already here: \(inbox.name(of: link.addedBy)) sent it \(LinkFormat.ago(link.addedAt).lowercased())"
        } else {
            toast = "Sent"
            if tab != .search { tab = .sent }
            fastPollUntil = .now.addingTimeInterval(15)
            ShareSuggestions.donateSend(in: inbox, groupID: result.link.groupID)
        }
    }

    // MARK: Chats

    /// Starts a chat with me and `members` in it, and shows it. Throws so the sheet can say why.
    func startChat(name: String, members: [String]) async throws {
        let group = try await chatChange { try await self.client.createGroup(name: name, members: members) }
        chat = group.id
        toast = "Started \(inbox.title(of: group))"
    }

    func renameChat(_ group: LinkGroup, to name: String) async throws {
        try await chatChange { try await self.client.renameGroup(group.id, to: name) }
    }

    func setChatMuted(_ group: LinkGroup, muted: Bool, until: Date? = nil) async throws {
        let session = sessionID
        let client = client
        let save = chatMuteSaves.enqueue(group.id) {
            guard session == self.sessionID else { throw CancellationError() }
            // Apply the response inside the queue too, so an older response cannot replace a newer one.
            return try await self.chatChange {
                try await client.setGroupMuted(group.id, muted: muted, until: until)
            }
        }
        _ = try await save.value
    }

    func addPeople(_ members: [String], to group: LinkGroup) async throws {
        let updated = try await chatChange { try await self.client.addMembers(members, to: group.id) }
        let added = members.compactMap { inbox.user($0)?.name }
        toast = "Added \(LinkFormat.names(added)) to \(inbox.title(of: updated))"
    }

    /// Its links leave my lists; the ones I sent stay in the chat for everyone else.
    func leaveChat(_ group: LinkGroup) async {
        let title = inbox.title(of: group)
        let before = inbox, chatBefore = chat
        if chat == group.id { chat = nil }
        applyLocally { $0.leaving(group: group.id) }
        ShareSuggestions.forget(group)
        // Offline I'm still in it, and the refresh can't put it back: setInbox re-donates its suggestion.
        await perform(onFailure: {
            self.setInbox(before)
            self.chat = chatBefore
        }) {
            try await self.client.leaveGroup(group.id)
            self.toast = "Left \(title)"
        }
    }

    /// Applies the server's copy of a chat at once (picker, lists, widgets), then refreshes.
    @discardableResult
    private func chatChange(_ save: @escaping () async throws -> LinkGroup) async throws -> LinkGroup {
        let session = sessionID
        do {
            let group = try await save()
            guard session == sessionID else { throw CancellationError() }
            applyLocally { $0.updating(group) }
            ShareSuggestions.seedIfNeeded(in: inbox)
            Task { await refresh() }
            return group
        } catch APIError.signedOut {
            if session == sessionID { endSession() }
            throw APIError.signedOut
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

    func nudge(_ link: SharedLink, people: [String]? = nil) async {
        await perform { self.patch(try await self.client.nudge(link.id, people: people)) }
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
            // From a widget, it may have seen a newer inbox than this (backgrounded) app has.
            showPage { $0.id == id }
        case .link(let token):
            // A shared /l/ link, e.g. tapped in Messages: its page, when it's in my inbox.
            showPage { $0.token == token }
        case .add:
            swipeQueue = nil
            addPrefill = ""
            showAddSheet = true
        case .invite(let invite):
            if token == nil {
                pendingInvite = invite
                errorMessage = nil
            } else {
                // Already in: the link is still how a friend brings them into a chat.
                Task { await acceptInvite(invite) }
            }
        case .group(let id):
            guard let id = Int(id) else { break }
            if inbox.group(id) != nil {
                showChat(id)
            } else {
                // A chat I've just been added to, newer than this (backgrounded) app's inbox.
                Task {
                    await refresh()
                    if inbox.group(id) != nil { showChat(id) }
                }
            }
        case .inbox, nil:
            break
        }
    }

    /// The page of the first link that matches, refreshing once if this (backgrounded) app's inbox
    /// doesn't have it yet; nothing if it still isn't there.
    private func showPage(where matches: @escaping (SharedLink) -> Bool) {
        if let link = inbox.links.first(where: matches) {
            showPage(link)
        } else {
            Task {
                await refresh()
                if let link = inbox.links.first(where: matches) { showPage(link) }
            }
        }
    }

    // MARK: Navigation

    /// A chat's lists, from a deep link: the tab showing goes back to its list, off any link page.
    private func showChat(_ id: Int) {
        swipeQueue = nil
        chat = id
        paths[tab] = []
    }

    /// A row's link page, on top of that row's list.
    func showPage(_ link: SharedLink, on tab: InboxTab) {
        paths[tab] = [link.id]
    }

    /// A link's page on the tab whose list has it, e.g. from a widget.
    func showPage(_ link: SharedLink) {
        swipeQueue = nil
        if let chat, link.groupID != chat { self.chat = nil } // e.g. a push from another chat
        let tab = InboxTab(inbox.home(of: link))
        self.tab = tab
        paths[tab] = [link.id]
    }

    /// What RootView keeps in SceneStorage.
    struct Navigation: Codable, Equatable {
        var tab: InboxTab
        var paths: [InboxTab: [Int]]
        var chat: Int?
    }

    var navigation: Navigation { Navigation(tab: tab, paths: paths, chat: chat) }

    /// Puts back the tab and pages that were showing when iOS ended the app, minus links that
    /// have gone since. A page a widget already opened wins.
    func restore(_ saved: Navigation) {
        guard paths.values.allSatisfy(\.isEmpty) else { return }
        let ids = Set(inbox.links.map(\.id))
        tab = saved.tab
        paths = saved.paths.mapValues { $0.filter(ids.contains) }
        chat = saved.chat.flatMap { inbox.group($0)?.id }
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
