import AppIntents
import LinksKit
import WidgetKit

/// "Save to Links" for Shortcuts, Siri, Spotlight and the Action button. Runs without opening
/// the app, using the same session as the app.
struct SaveLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Link"
    static let description = IntentDescription("Sends a TikTok, reel or any link to your friends in Links.")

    @Parameter(title: "Link", description: "A link, or text that contains one.",
               inputOptions: String.IntentInputOptions(keyboardType: .URL, capitalizationType: .none,
                                                       autocorrect: false))
    var link: String

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$link) to Links") {
            \.$note
        }
    }

    init() {}

    init(link: String, note: String? = nil) {
        self.link = link
        self.note = note
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard SessionStore.isSignedIn else {
            throw IntentError.message("Open Links and sign in first.")
        }
        do {
            let result = try await APIClient().add(link, note: note ?? "")
            InboxSnapshot.update { state in
                if !state.links.contains(where: { $0.id == result.link.id }) { state.links.insert(result.link, at: 0) }
            }
            WidgetCenter.shared.reloadAllTimelines()
            if result.duplicate {
                return .result(value: result.link.url.absoluteString, dialog: "That one's already in Links.")
            }
            if let state = InboxSnapshot.load() { ShareSuggestions.donateSend(in: state) }
            return .result(value: result.link.url.absoluteString, dialog: "Sent to Links.")
        } catch {
            throw IntentError.message(error.localizedDescription)
        }
    }
}

/// "How many links do I have to watch?"
struct ToWatchCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Links to Watch"
    static let description = IntentDescription("Tells you how many links you haven't watched yet.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard SessionStore.isSignedIn else { throw IntentError.message("Open Links and sign in first.") }
        let state = (try? await APIClient().state()) ?? InboxSnapshot.load() ?? .empty
        let count = state.toWatch.count
        let dialog: IntentDialog = switch count {
        case 0: "You're all caught up."
        case 1: "You have 1 link to watch, from \(state.name(of: state.toWatch[0].addedBy))."
        default: "You have \(count) links to watch."
        }
        return .result(value: count, dialog: dialog)
    }
}

/// Opens the app straight to the New Link sheet.
struct NewLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "New Link"
    static let description = IntentDescription("Opens Links to paste and send a link.")
    static let openAppWhenRun = true

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.addPrefill = ""
        model.showAddSheet = true
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): "\(text)"
        }
    }
}

struct LinksShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SaveLinkIntent(), phrases: [
            "Send a link with \(.applicationName)",
            "Save a link to \(.applicationName)",
        ], shortTitle: "Send Link", systemImageName: "paperplane")
        AppShortcut(intent: ToWatchCountIntent(), phrases: [
            "What's in \(.applicationName)",
            "How many \(.applicationName) do I have to watch",
        ], shortTitle: "Links to Watch", systemImageName: "play.rectangle.on.rectangle")
        AppShortcut(intent: NewLinkIntent(), phrases: [
            "New \(.applicationName)",
        ], shortTitle: "New Link", systemImageName: "plus")
    }
    static let shortcutTileColor: ShortcutTileColor = .pink
}
