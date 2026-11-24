import LinksKit
import PhotosUI
import SwiftUI

/// My avatar at the top of every tab, which opens my profile (#74).
struct ProfileButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false
    /// What a row asked for once the profile has closed: the tour and the claim sheet are shown
    /// from further up, which SwiftUI can't do while this sheet is still up.
    @State private var afterClose: (() -> Void)?

    var body: some View {
        Button {
            model.isProfileOpen = true
            showing = true
        } label: {
            if model.isDeletingAccount {
                ProgressView()
                    .accessibilityLabel("Deleting account")
            } else {
                AvatarView(user: model.me, size: 30)
                    .accessibilityLabel("Profile")
            }
        }
        .disabled(model.isDeletingAccount)
        .accessibilityIdentifier("account")
        #if DEBUG
        .accessibilityValue(model.hasDroppedFeatureTourForReplay ? "Feature tour presentation dropped" : "")
        #endif
        .sheet(isPresented: $showing, onDismiss: {
            model.isProfileOpen = false
            afterClose?()
            afterClose = nil
            model.showTourIfNeeded()
        }) {
            ProfileSheet(afterClose: $afterClose).environment(model)
        }
    }
}

/// Who I am, my friends, the app's settings and help, and signing out or deleting the account.
struct ProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Binding var afterClose: (() -> Void)?
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmingDelete = false
    @State private var showingAbout = false
    @State private var failure: String?
    /// A rename that failed: its alert comes back with what was typed once the error is closed.
    @State private var retryingRename = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var savingPhoto = false
    @State private var choosingPhoto = false

    /// Spells out what goes and what stays, since none of it can come back.
    private var deleteWarning: String {
        let sent = model.inbox.links(for: .sent).count
        let links = switch sent {
        case 0: ""
        case 1: ", the link you sent and its note (your friends lose it too)"
        default: ", the \(sent) links you sent and their notes (your friends lose them too)"
        }
        return "This permanently deletes your Links account\(links), your seen marks and your reactions. "
            + "This can't be undone."
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return info?["CFBundleVersion"].map { "\(short) (\($0))" } ?? short
    }

    private var friendCount: String {
        switch model.inbox.otherPeople.count {
        case 0: "Just you so far"
        case 1: "1 friend"
        case let count: "\(count) friends"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                header
                Section {
                    photoRow
                    row("Change Display Name", systemImage: "pencil") {
                        nameDraft = model.me?.name ?? ""
                        renaming = true
                    }
                    if !model.claimable.isEmpty {
                        row("Claim Earlier Links…", systemImage: "clock.arrow.circlepath") {
                            close { model.showClaimSheet = true }
                        }
                    }
                }
                Section {
                    NavigationLink {
                        PeopleList().toolbar { doneButton }
                    } label: {
                        Label("People", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("people")
                    NavigationLink {
                        BlockedPeopleList().toolbar { doneButton }
                    } label: {
                        Label("Blocked People", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("blockedPeople")
                } header: {
                    Text("Friends")
                } footer: {
                    Text(friendCount)
                }
                if let settings = model.notifications {
                    Section {
                        notificationToggle("When someone sees my link", systemImage: "eye",
                                           isOn: settings.watched, id: "notify.watched") {
                            try await model.setNotifications(watched: $0)
                        }
                        notificationToggle("When someone reacts to my link", systemImage: "face.smiling",
                                           isOn: settings.reactions, id: "notify.reactions") {
                            try await model.setNotifications(reactions: $0)
                        }
                    } header: {
                        Text("Notify Me")
                    } footer: {
                        Text("If someone sees a link and reacts within a minute, you get one notification for both.")
                    }
                }
                Section("Settings") {
                    // iOS asks only once, so this is where people who said no (or only allowed the
                    // badge, before notifications) turn them on.
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        row("Notification Settings", systemImage: "bell.badge") { openURL(url) }
                    }
                    row("How to Share to Links", systemImage: "square.and.arrow.up") {
                        close { model.startTour(at: .shareSheet) }
                    }
                    row("Show Tour Again", systemImage: "sparkles") {
                        close { model.startTour() }
                    }
                    row("What's New", systemImage: "gift") {
                        close { model.replayFeatureTours() }
                    }
                    .accessibilityIdentifier("profile.whatsNew")
                    NavigationLink { WrappedView() } label: {
                        Label("Links Wrapped", systemImage: "sparkles.rectangle.stack")
                    }
                    .accessibilityIdentifier("profile.wrapped")
                }
                Section("Help") {
                    if let support = LinksConfig.supportURL {
                        ContactSupportButton(url: support)
                    }
                    Link(destination: LinksConfig.privacyPolicyURL) {
                        Label {
                            Text("Privacy Policy").foregroundStyle(Color.primary)
                        } icon: {
                            Image(systemName: "lock.shield")
                        }
                    }
                    row("About Links", systemImage: "info.circle") { showingAbout = true }
                }
                Section {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await model.signOut() }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        HStack {
                            Label("Delete Account…", systemImage: "person.crop.circle.badge.xmark")
                            if model.isDeletingAccount {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                } footer: {
                    Text("Links \(Self.version)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .disabled(model.isDeletingAccount)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                doneButton
            }
            .alert("Delete Your Account?", isPresented: $confirmingDelete) {
                Button("Delete Account", role: .destructive) {
                    Task {
                        do { try await model.deleteAccount() } catch { failure = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteWarning)
            }
            .alert("Links \(Self.version)", isPresented: $showingAbout) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(Platform.trademarkNotice())
            }
            .alert("Display Name", isPresented: $renaming) {
                TextField("Name", text: $nameDraft)
                    .textInputAutocapitalization(.words)
                Button("Save") {
                    Task {
                        do {
                            try await model.rename(to: nameDraft)
                        } catch {
                            retryingRename = true
                            failure = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This is what your friends see next to the links you send.")
            }
            .failureAlert($failure)
            // Presented from the list, not the photo row: a save re-renders that row (and swaps Add
            // for the Change menu), which dropped a picker presented from inside it.
            .photosPicker(isPresented: $choosingPhoto, selection: $pickedPhoto, matching: .images,
                          preferredItemEncoding: .compatible)
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                savePhoto {
                    // .compatible hands over HEIC photos as JPEG.
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw APIError.server("That photo couldn't be opened. Try another one.")
                    }
                    try await model.setPhoto(data)
                }
            }
            .onChange(of: failure) { _, message in
                guard message == nil, retryingRename else { return }
                retryingRename = false
                renaming = true
            }
        }
        // RootView's toast is under this sheet, so "Copied" and "Unblocked" show here instead.
        .overlay(alignment: .bottom) { ToastView() }
    }

    /// On People and Blocked People too, so the profile closes from wherever it is. This view's
    /// dismiss closes the sheet; one read inside a pushed page would only go back.
    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
    }

    private var header: some View {
        Section {
            VStack(spacing: 6) {
                AvatarView(user: model.me, size: 88)
                    .overlay {
                        if savingPhoto {
                            ProgressView()
                                .frame(width: 88, height: 88)
                                .background(.ultraThinMaterial, in: .circle)
                                .accessibilityLabel("Saving photo")
                        }
                    }
                    .padding(.bottom, 6)
                Text(model.me?.name ?? "")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("profile.name")
                if let email = model.me?.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile.email")
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .contain)
        }
    }

    /// A settings-style row: the icon in the accent color, the title in the text color.
    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, systemImage: systemImage) }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    /// Straight to the photo picker; once there's a photo, a menu that can also remove it (#97).
    @ViewBuilder private var photoRow: some View {
        Group {
            if model.me?.avatar == nil {
                row("Add Profile Photo", systemImage: "camera") { choosingPhoto = true }
            } else {
                Menu {
                    Button("Choose Photo", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        savePhoto { try await model.removePhoto() }
                    }
                } label: {
                    rowLabel("Change Profile Photo", systemImage: "camera")
                }
            }
        }
        .disabled(savingPhoto)
        .accessibilityIdentifier("profile.photo")
    }

    private func savePhoto(_ save: @escaping () async throws -> Void) {
        savingPhoto = true
        Task {
            do { try await save() } catch { failure = error.localizedDescription }
            savingPhoto = false
        }
    }

    /// Flips at once; a save that fails flips it back and says why.
    private func notificationToggle(_ title: String, systemImage: String, isOn: Bool, id: String,
                                    save: @escaping (Bool) async throws -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in
            Task {
                do { try await save(on) } catch { failure = error.localizedDescription }
            }
        })) {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(id)
    }

    private func close(then action: @escaping () -> Void) {
        afterClose = action
        dismiss()
    }
}
