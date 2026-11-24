import LinksKit
import SwiftUI

@MainActor @Observable
final class LinkThread {
    private(set) var comments: [LinkComment] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var saving = false
    var loadError: String?
    var saveError: String?
    var draft = ""
    var editing: LinkComment?
    var deleting: LinkComment?
    var reporting: LinkComment?
    private var reload = false

    var body: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSend: Bool { !saving && loaded && LinkComment.isValidBody(draft) }

    func load(_ linkID: Int, model: AppModel) async {
        guard !saving else { return }
        guard !loading else { reload = true; return }
        loading = true
        repeat {
            reload = false
            do {
                let fetched = try await model.loadComments(linkID)
                try Task.checkCancellation()
                comments = fetched
                loaded = true
                loadError = nil
                model.markCommentsRead(linkID, comments: fetched)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                loadError = error.localizedDescription
            }
        } while reload && !Task.isCancelled
        loading = false
    }

    func send(_ linkID: Int, model: AppModel) async {
        guard canSend else { return }
        saving = true
        saveError = nil
        do {
            try await model.saveComment(linkID, comment: editing, body: body)
            draft = ""
            editing = nil
        } catch {
            saveError = error.localizedDescription
        }
        saving = false
        if saveError == nil { await load(linkID, model: model) }
    }

    func delete(_ comment: LinkComment, model: AppModel) async {
        guard !saving else { return }
        saving = true
        saveError = nil
        do {
            try await model.deleteComment(comment)
            comments.removeAll { $0.id == comment.id }
            if editing?.id == comment.id { cancelEditing() }
        } catch {
            saveError = error.localizedDescription
        }
        saving = false
        await load(comment.linkID, model: model)
    }

    func cancelEditing() {
        editing = nil
        draft = ""
    }

    func report(_ comment: LinkComment, reason: ReportReason, model: AppModel) async {
        guard !saving else { return }
        saving = true
        saveError = nil
        do {
            try await model.reportComment(comment, reason: reason)
            comments.removeAll { $0.id == comment.id }
        } catch {
            saveError = error.localizedDescription
        }
        saving = false
        await load(comment.linkID, model: model)
    }
}

struct CommentThreadView: View {
    @Environment(AppModel.self) private var model
    @Bindable var thread: LinkThread
    let linkID: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Comments").font(.headline)
            if let error = thread.loadError {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("Try Loading Comments Again") { Task { await thread.load(linkID, model: model) } }
                    .accessibilityIdentifier("comments.retry")
            } else if !thread.loaded {
                ProgressView("Loading comments…")
            } else if thread.comments.isEmpty {
                Text("No comments yet. Start the conversation.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("comments.empty")
            }
            ForEach(thread.comments) { comment in
                bubble(comment)
                    .id("comment.\(comment.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Delete this comment?", isPresented: Binding(
            get: { thread.deleting != nil }, set: { if !$0 { thread.deleting = nil } }
        ), titleVisibility: .visible) {
            if let comment = thread.deleting {
                Button("Delete Comment", role: .destructive) {
                    Task { await thread.delete(comment, model: model) }
                }
            }
        }
        .confirmationDialog("Report this comment?", isPresented: Binding(
            get: { thread.reporting != nil }, set: { if !$0 { thread.reporting = nil } }
        ), titleVisibility: .visible) {
            if let comment = thread.reporting {
                ForEach(ReportReason.allCases) { reason in
                    Button(reason.title) { Task { await thread.report(comment, reason: reason, model: model) } }
                }
            }
        } message: {
            Text("It's hidden for you, and whoever runs Links gets your report. The author isn't told.")
        }
    }

    private func bubble(_ comment: LinkComment) -> some View {
        let mine = comment.person == model.inbox.me
        return HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 28) }
            if !mine { AvatarView(user: model.inbox.user(comment.person), size: 28) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mine ? "You" : model.inbox.name(of: comment.person)).fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text("\(LinkFormat.ago(comment.createdAt))\(comment.editedAt == nil ? "" : " · Edited")")
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(comment.body).textSelection(.enabled)
                if mine {
                    HStack(spacing: 20) {
                        Button("Edit") { thread.editing = comment; thread.draft = comment.body }
                            .accessibilityIdentifier("comment.edit.\(comment.id)")
                        Button("Delete", role: .destructive) { thread.deleting = comment }
                            .accessibilityIdentifier("comment.delete.\(comment.id)")
                    }
                    .font(.caption).disabled(thread.saving)
                } else {
                    Button("Report…") { thread.reporting = comment }
                        .font(.caption).disabled(thread.saving)
                        .accessibilityIdentifier("comment.report.\(comment.id)")
                }
            }
            .padding(12)
            .background(mine ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                        in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("comment.\(comment.id)")
            if !mine { Spacer(minLength: 28) }
        }
    }
}

struct CommentComposer: View {
    @Environment(AppModel.self) private var model
    @Bindable var thread: LinkThread
    let linkID: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if thread.editing != nil {
                HStack {
                    Text("Editing comment").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { thread.cancelEditing() }.disabled(thread.saving)
                }
            }
            if let error = thread.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("comments.saveError")
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a comment…", text: $thread.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 18))
                    .disabled(thread.saving)
                    .accessibilityLabel("Comment")
                    .accessibilityIdentifier("comments.draft")
                Button(thread.editing == nil ? "Send" : "Save") {
                    Task { await thread.send(linkID, model: model) }
                }
                .fontWeight(.semibold)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!thread.canSend)
                .accessibilityIdentifier("comments.send")
            }
            if !thread.draft.isEmpty {
                Text("\(thread.body.unicodeScalars.count)/\(LinkComment.bodyLimit)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(thread.body.unicodeScalars.count > LinkComment.bodyLimit ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("\(thread.body.unicodeScalars.count) of \(LinkComment.bodyLimit) characters")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }
}
